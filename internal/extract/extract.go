package extract

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"

	sitter "github.com/smacker/go-tree-sitter"
	"github.com/smacker/go-tree-sitter/javascript"
	"github.com/smacker/go-tree-sitter/typescript/tsx"
	"github.com/smacker/go-tree-sitter/typescript/typescript"

	"github.com/justasmonkev/i18n-string-check/internal/normalize"
)

type Literal struct {
	File              string `json:"file"`
	Line              int    `json:"line"`
	Column            int    `json:"column"`
	Literal           string `json:"literal"`
	NormalizedLiteral string `json:"normalizedLiteral"`
}

func File(path string, minLength int) ([]Literal, error) {
	content, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return Bytes(path, content, minLength)
}

// MatchFunc reports whether a normalized literal is worth keeping. It lets
// callers that only care about literals matching an index skip the expensive
// per-literal context filters (cgo ancestor walks) for everything else.
type MatchFunc func(normalized string) bool

var parserPool = sync.Pool{
	New: func() any { return sitter.NewParser() },
}

var queryCursorPool = sync.Pool{
	New: func() any { return sitter.NewQueryCursor() },
}

const ignoreMarker = "i18n-string-check-ignore"

type literalKind int

const (
	kindString literalKind = iota
	kindTemplate
	kindJSXText
)

// nodeClass groups the node types the context filters care about. Classifying
// by numeric symbol id (one cgo call) replaces Node.Type(), which crosses cgo
// and allocates a Go string on every call.
type nodeClass uint8

const (
	classNone nodeClass = iota
	classPair
	classArguments
	classCallExpression
	classTypeKey
	classImportExport
	classJSXAttribute
	classJSXElement
	classObject
	classScopeStop
	classTemplateSubstitution
	classAttributeName
)

var classByName = map[string]nodeClass{
	"pair":                     classPair,
	"arguments":                classArguments,
	"call_expression":          classCallExpression,
	"property_signature":       classTypeKey,
	"method_signature":         classTypeKey,
	"enum_assignment":          classTypeKey,
	"import_statement":         classImportExport,
	"export_statement":         classImportExport,
	"jsx_attribute":            classJSXAttribute,
	"jsx_element":              classJSXElement,
	"jsx_self_closing_element": classJSXElement,
	"object":                   classObject,
	"statement_block":          classScopeStop,
	"program":                  classScopeStop,
	"template_substitution":    classTemplateSubstitution,
	"property_identifier":      classAttributeName,
	"identifier":               classAttributeName,
	"nested_identifier":        classAttributeName,
}

// langSupport holds the per-language pieces of the hot path: a precompiled
// query that finds candidate literal nodes inside C tree-sitter code (one cgo
// crossing per candidate instead of several per AST node), and a symbol-id to
// nodeClass table for cheap ancestor classification.
type langSupport struct {
	query *sitter.Query
	// kinds maps a query capture index to the literal kind it captures,
	// avoiding a cgo Node.Type() call per candidate.
	kinds   []literalKind
	classes []nodeClass
}

func newLangSupport(lang *sitter.Language) (*langSupport, error) {
	const withJSX = "(string) @string\n(template_string) @template\n(jsx_text) @jsxtext"
	const withoutJSX = "(string) @string\n(template_string) @template"
	query, err := sitter.NewQuery([]byte(withJSX), lang)
	if err != nil {
		// Grammars without JSX support (plain TypeScript) reject jsx_text.
		query, err = sitter.NewQuery([]byte(withoutJSX), lang)
		if err != nil {
			return nil, err
		}
	}
	ls := &langSupport{query: query}
	for i := uint32(0); i < query.CaptureCount(); i++ {
		switch query.CaptureNameForId(i) {
		case "string":
			ls.kinds = append(ls.kinds, kindString)
		case "template":
			ls.kinds = append(ls.kinds, kindTemplate)
		case "jsxtext":
			ls.kinds = append(ls.kinds, kindJSXText)
		default:
			return nil, fmt.Errorf("unexpected capture %q", query.CaptureNameForId(i))
		}
	}
	ls.classes = make([]nodeClass, lang.SymbolCount())
	for symbol := uint32(0); symbol < lang.SymbolCount(); symbol++ {
		if class, ok := classByName[lang.SymbolName(sitter.Symbol(symbol))]; ok {
			ls.classes[symbol] = class
		}
	}
	return ls, nil
}

func (ls *langSupport) classOf(node *sitter.Node) nodeClass {
	symbol := uint32(node.Symbol())
	if symbol >= uint32(len(ls.classes)) {
		return classNone
	}
	return ls.classes[symbol]
}

var (
	typescriptSupport = sync.OnceValues(func() (*langSupport, error) { return newLangSupport(typescript.GetLanguage()) })
	tsxSupport        = sync.OnceValues(func() (*langSupport, error) { return newLangSupport(tsx.GetLanguage()) })
	javascriptSupport = sync.OnceValues(func() (*langSupport, error) { return newLangSupport(javascript.GetLanguage()) })
)

func Bytes(path string, content []byte, minLength int) ([]Literal, error) {
	return BytesFiltered(path, content, minLength, nil)
}

// BytesFiltered is Bytes with an optional worth filter: literals whose
// normalized form fails the filter are dropped before the context checks run.
// A nil filter keeps every literal, matching Bytes.
func BytesFiltered(path string, content []byte, minLength int, worth MatchFunc) ([]Literal, error) {
	language, ls, err := languageForPath(path)
	if err != nil {
		return nil, err
	}
	parser := parserPool.Get().(*sitter.Parser)
	parser.SetLanguage(language)
	tree, err := parser.ParseCtx(context.Background(), nil, content)
	parserPool.Put(parser)
	if err != nil {
		return nil, err
	}
	defer tree.Close()
	root := tree.RootNode()
	if root.HasError() {
		return nil, fmt.Errorf("parse error in %s", path)
	}

	w := &walker{
		content:     content,
		minLength:   minLength,
		path:        path,
		lang:        ls,
		worth:       worth,
		ignoreLines: ignoreMarkerLines(content),
	}

	cursor := queryCursorPool.Get().(*sitter.QueryCursor)
	cursor.Exec(ls.query, root)
	for {
		match, ok := cursor.NextMatch()
		if !ok {
			break
		}
		for _, capture := range match.Captures {
			w.visit(ls.kinds[capture.Index], capture.Node)
		}
	}
	queryCursorPool.Put(cursor)

	// Query matches arrive in traversal order; sort to guarantee document
	// order for callers and tests.
	sort.Slice(w.literals, func(i, j int) bool {
		if w.literals[i].Line != w.literals[j].Line {
			return w.literals[i].Line < w.literals[j].Line
		}
		return w.literals[i].Column < w.literals[j].Column
	})
	return w.literals, nil
}

type walker struct {
	content   []byte
	minLength int
	path      string
	lang      *langSupport
	worth     MatchFunc
	// ignoreLines marks zero-based rows that contain the inline ignore marker.
	// It is nil when the marker is absent from the file (the common case).
	ignoreLines []bool
	literals    []Literal
}

// ignoreMarkerLines scans the file once and records which rows contain the
// inline ignore marker. When the marker is absent (the common case) it returns
// nil so the per-literal check is a no-op instead of re-splitting the file.
func ignoreMarkerLines(content []byte) []bool {
	if !bytes.Contains(content, []byte(ignoreMarker)) {
		return nil
	}
	var lines []bool
	for _, line := range bytes.Split(content, []byte("\n")) {
		lines = append(lines, bytes.Contains(line, []byte(ignoreMarker)))
	}
	return lines
}

func languageForPath(path string) (*sitter.Language, *langSupport, error) {
	switch strings.ToLower(filepath.Ext(path)) {
	case ".ts":
		ls, err := typescriptSupport()
		return typescript.GetLanguage(), ls, err
	case ".tsx", ".jsx":
		ls, err := tsxSupport()
		return tsx.GetLanguage(), ls, err
	default:
		ls, err := javascriptSupport()
		return javascript.GetLanguage(), ls, err
	}
}

func (w *walker) visit(kind literalKind, node *sitter.Node) {
	var value string
	switch kind {
	case kindString:
		decoded, ok := decodeQuoted(node.Content(w.content))
		if !ok {
			return
		}
		value = decoded
	case kindTemplate:
		if w.hasSubstitution(node) {
			return
		}
		decoded, ok := decodeTemplate(node.Content(w.content))
		if !ok {
			return
		}
		value = decoded
	case kindJSXText:
		value = strings.TrimSpace(node.Content(w.content))
	}
	// Collapse whitespace once and reuse it for the length check, the stored
	// literal, and the normalized form instead of recomputing it three times.
	collapsed := normalize.CollapseWhitespace(value)
	if len(collapsed)+strings.Count(collapsed, " ") < w.minLength {
		return
	}
	normalized := strings.ToLower(collapsed)
	if normalized == "" {
		return
	}
	// The worth filter runs before the context checks: matching against the
	// index is a hash lookup, while the context checks walk the ancestor
	// chain through cgo, so uninteresting literals never pay for that walk.
	if w.worth != nil && !w.worth(normalized) {
		return
	}
	if kind == kindString && !w.shouldScanString(node) {
		return
	}
	point := node.StartPoint()
	if w.hasInlineIgnore(int(point.Row)) {
		return
	}
	w.literals = append(w.literals, Literal{
		File:              w.path,
		Line:              int(point.Row) + 1,
		Column:            int(point.Column) + 1,
		Literal:           collapsed,
		NormalizedLiteral: normalized,
	})
}

func (w *walker) hasInlineIgnore(zeroBasedRow int) bool {
	if w.ignoreLines == nil {
		return false
	}
	for _, row := range []int{zeroBasedRow, zeroBasedRow - 1} {
		if row >= 0 && row < len(w.ignoreLines) && w.ignoreLines[row] {
			return true
		}
	}
	return false
}

// shouldScanString applies all context filters (object keys, type literal
// keys, import/export sources, require() arguments, JSX attributes) in a
// single walk up the ancestor chain. Every Parent()/Symbol() call crosses
// cgo, so the filters share one traversal instead of re-walking per filter.
//
// Rejection filters take precedence over the JSX attribute visibility check,
// matching the historical evaluation order: each filter scans upward until
// its own stop node, independent of the others.
func (w *walker) shouldScanString(node *sitter.Node) bool {
	parent := node.Parent()
	if parent == nil {
		return true
	}
	switch w.lang.classOf(parent) {
	case classPair:
		key := parent.ChildByFieldName("key")
		if key != nil && key.Equal(node) {
			return false
		}
	case classArguments:
		call := parent.Parent()
		if call != nil && w.lang.classOf(call) == classCallExpression {
			fn := call.ChildByFieldName("function")
			if fn != nil && fn.Content(w.content) == "require" {
				return false
			}
		}
	}

	// Active flags track which filters are still scanning; each filter stops
	// at its own boundary node types.
	typeKeyActive, importActive, jsxActive := true, true, true
	var jsxAttribute *sitter.Node
	for p := parent; p != nil; p = p.Parent() {
		switch w.lang.classOf(p) {
		case classTypeKey:
			if typeKeyActive {
				return false
			}
		case classImportExport:
			if importActive {
				return false
			}
		case classJSXAttribute:
			if jsxActive {
				jsxAttribute = p
				jsxActive = false
			}
		case classJSXElement:
			jsxActive = false
		case classObject:
			typeKeyActive = false
		case classScopeStop:
			typeKeyActive, importActive, jsxActive = false, false, false
		}
		if !typeKeyActive && !importActive && !jsxActive {
			break
		}
	}
	if jsxAttribute != nil {
		return w.isVisibleJSXAttribute(jsxAttribute)
	}
	return true
}

func (w *walker) isVisibleJSXAttribute(attribute *sitter.Node) bool {
	name := ""
	for i := 0; i < int(attribute.ChildCount()); i++ {
		child := attribute.Child(i)
		if child == nil {
			continue
		}
		if w.lang.classOf(child) == classAttributeName {
			name = child.Content(w.content)
			break
		}
	}
	switch name {
	case "aria-label", "title", "placeholder", "alt", "label":
		return true
	default:
		return false
	}
}

func (w *walker) hasSubstitution(node *sitter.Node) bool {
	for i := 0; i < int(node.ChildCount()); i++ {
		child := node.Child(i)
		if child != nil && w.lang.classOf(child) == classTemplateSubstitution {
			return true
		}
	}
	return false
}

func decodeQuoted(raw string) (string, bool) {
	if len(raw) < 2 {
		return "", false
	}
	quote := raw[0]
	if quote != '\'' && quote != '"' {
		return "", false
	}
	return unquoteJS(raw[1:len(raw)-1], quote), true
}

func decodeTemplate(raw string) (string, bool) {
	if len(raw) < 2 || raw[0] != '`' || raw[len(raw)-1] != '`' {
		return "", false
	}
	return unquoteJS(raw[1:len(raw)-1], '`'), true
}

func unquoteJS(value string, quote byte) string {
	if strings.IndexByte(value, '\\') < 0 {
		return value
	}
	var out strings.Builder
	for len(value) > 0 {
		r, _, tail, err := strconv.UnquoteChar(value, quote)
		if err != nil {
			return value
		}
		out.WriteRune(r)
		value = tail
	}
	return out.String()
}
