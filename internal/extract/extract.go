package extract

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

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

func Bytes(path string, content []byte, minLength int) ([]Literal, error) {
	parser := sitter.NewParser()
	parser.SetLanguage(languageForPath(path))
	tree, err := parser.ParseCtx(context.Background(), nil, content)
	if err != nil {
		return nil, err
	}
	root := tree.RootNode()
	if root.HasError() {
		return nil, fmt.Errorf("parse error in %s", path)
	}

	var literals []Literal
	walk(root, content, minLength, &literals, path)
	return literals, nil
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

func walk(node *sitter.Node, content []byte, minLength int, literals *[]Literal, path string) {
	if node == nil || node.IsNull() {
		return
	}

	switch node.Type() {
	case "string":
		if shouldScanString(node, content) {
			addLiteral(node, content, minLength, literals, path, decodeQuoted)
		}
	case "template_string":
		if !hasChildType(node, "template_substitution") {
			addLiteral(node, content, minLength, literals, path, decodeTemplate)
		}
	case "jsx_text":
		addLiteral(node, content, minLength, literals, path, func(raw string) (string, bool) {
			return strings.TrimSpace(raw), true
		})
	}

	for i := 0; i < int(node.ChildCount()); i++ {
		walk(node.Child(i), content, minLength, literals, path)
	}
}

func addLiteral(node *sitter.Node, content []byte, minLength int, literals *[]Literal, path string, decode func(string) (string, bool)) {
	value, ok := decode(node.Content(content))
	if !ok {
		return
	}
	if normalize.TrimmedLength(value) < minLength {
		return
	}
	normalized := normalize.Normalize(value)
	if normalized == "" {
		return
	}
	point := node.StartPoint()
	if hasInlineIgnore(content, int(point.Row)) {
		return
	}
	*literals = append(*literals, Literal{
		File:              path,
		Line:              int(point.Row) + 1,
		Column:            int(point.Column) + 1,
		Literal:           normalize.CollapseWhitespace(value),
		NormalizedLiteral: normalized,
	})
}

func hasInlineIgnore(content []byte, zeroBasedRow int) bool {
	lines := strings.Split(string(content), "\n")
	for _, row := range []int{zeroBasedRow, zeroBasedRow - 1} {
		if row >= 0 && row < len(lines) && strings.Contains(lines[row], "i18n-string-check-ignore") {
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
