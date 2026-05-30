package extract

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"path/filepath"
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

var parserPool = sync.Pool{
	New: func() any { return sitter.NewParser() },
}

const ignoreMarker = "i18n-string-check-ignore"

func Bytes(path string, content []byte, minLength int) ([]Literal, error) {
	parser := parserPool.Get().(*sitter.Parser)
	parser.SetLanguage(languageForPath(path))
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
		ignoreLines: ignoreMarkerLines(content),
	}
	w.walk(root)
	return w.literals, nil
}

type walker struct {
	content   []byte
	minLength int
	path      string
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

func languageForPath(path string) *sitter.Language {
	switch strings.ToLower(filepath.Ext(path)) {
	case ".ts":
		return typescript.GetLanguage()
	case ".tsx", ".jsx":
		return tsx.GetLanguage()
	default:
		return javascript.GetLanguage()
	}
}

func (w *walker) walk(node *sitter.Node) {
	if node == nil || node.IsNull() {
		return
	}

	switch node.Type() {
	case "string":
		if shouldScanString(node, w.content) {
			w.addLiteral(node, decodeQuoted)
		}
	case "template_string":
		if !hasChildType(node, "template_substitution") {
			w.addLiteral(node, decodeTemplate)
		}
	case "jsx_text":
		w.addLiteral(node, func(raw string) (string, bool) {
			return strings.TrimSpace(raw), true
		})
	}

	for i := 0; i < int(node.ChildCount()); i++ {
		w.walk(node.Child(i))
	}
}

func (w *walker) addLiteral(node *sitter.Node, decode func(string) (string, bool)) {
	value, ok := decode(node.Content(w.content))
	if !ok {
		return
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

func shouldScanString(node *sitter.Node, content []byte) bool {
	if isObjectKey(node) || isTypeLiteralKey(node) || isImportOrExportSource(node) || isRequireArg(node, content) {
		return false
	}
	if attribute := jsxAttributeAncestor(node); attribute != nil {
		return isVisibleJSXAttribute(attribute, content)
	}
	return true
}

func jsxAttributeAncestor(node *sitter.Node) *sitter.Node {
	for parent := node.Parent(); parent != nil && !parent.IsNull(); parent = parent.Parent() {
		switch parent.Type() {
		case "jsx_attribute":
			return parent
		case "jsx_element", "jsx_self_closing_element", "program", "statement_block":
			return nil
		}
	}
	return nil
}

func isObjectKey(node *sitter.Node) bool {
	parent := node.Parent()
	if parent == nil || parent.IsNull() || parent.Type() != "pair" {
		return false
	}
	key := parent.ChildByFieldName("key")
	return key != nil && !key.IsNull() && key.Equal(node)
}

func isTypeLiteralKey(node *sitter.Node) bool {
	for parent := node.Parent(); parent != nil && !parent.IsNull(); parent = parent.Parent() {
		switch parent.Type() {
		case "property_signature", "method_signature", "enum_assignment":
			return true
		case "statement_block", "program", "object":
			return false
		}
	}
	return false
}

func isImportOrExportSource(node *sitter.Node) bool {
	for parent := node.Parent(); parent != nil && !parent.IsNull(); parent = parent.Parent() {
		switch parent.Type() {
		case "import_statement", "export_statement":
			return true
		case "program", "statement_block":
			return false
		}
	}
	return false
}

func isRequireArg(node *sitter.Node, content []byte) bool {
	parent := node.Parent()
	if parent == nil || parent.IsNull() || parent.Type() != "arguments" {
		return false
	}
	call := parent.Parent()
	if call == nil || call.IsNull() || call.Type() != "call_expression" {
		return false
	}
	fn := call.ChildByFieldName("function")
	return fn != nil && !fn.IsNull() && fn.Content(content) == "require"
}

func isVisibleJSXAttribute(attribute *sitter.Node, content []byte) bool {
	name := ""
	for i := 0; i < int(attribute.ChildCount()); i++ {
		child := attribute.Child(i)
		if child == nil || child.IsNull() {
			continue
		}
		switch child.Type() {
		case "property_identifier", "identifier":
			name = child.Content(content)
		case "nested_identifier":
			name = child.Content(content)
		}
		if name != "" {
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

func hasChildType(node *sitter.Node, childType string) bool {
	for i := 0; i < int(node.ChildCount()); i++ {
		child := node.Child(i)
		if child != nil && !child.IsNull() && child.Type() == childType {
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
