package extract

import "testing"

func TestHardcodedStringIsExtracted(t *testing.T) {
	literals := extractSource(t, "component.tsx", `const label = "Sign in";`, 8)
	requireOneLiteral(t, literals, "Sign in")
}

func TestTestAssertionStringIsExtracted(t *testing.T) {
	literals := extractSource(t, "login.spec.ts", `await expect(button).toHaveText("Sign in");`, 8)
	requireOneLiteral(t, literals, "Sign in")
}

func TestProperTranslationKeyCanBeExtractedButWillNotMatchTranslationValues(t *testing.T) {
	literals := extractSource(t, "component.tsx", `const label = t("login.button");`, 8)
	requireOneLiteral(t, literals, "login.button")
}

func TestShortStringIgnored(t *testing.T) {
	literals := extractSource(t, "short.ts", `const label = "OK";`, 8)
	if len(literals) != 0 {
		t.Fatalf("expected no literals, got %#v", literals)
	}
}

func TestDynamicTemplateSkipped(t *testing.T) {
	literals := extractSource(t, "template.tsx", "const label = `Sign in ${name}`;", 8)
	if len(literals) != 0 {
		t.Fatalf("expected no literals, got %#v", literals)
	}
}

func TestStaticTemplateExtracted(t *testing.T) {
	literals := extractSource(t, "template.tsx", "const label = `Sign in`;", 8)
	requireOneLiteral(t, literals, "Sign in")
}

func TestCaseVariantExtractedWithNormalizedValue(t *testing.T) {
	literals := extractSource(t, "case.tsx", `const label = "SIGN IN";`, 8)
	requireOneLiteral(t, literals, "SIGN IN")
	if literals[0].NormalizedLiteral != "sign in" {
		t.Fatalf("NormalizedLiteral = %q, want sign in", literals[0].NormalizedLiteral)
	}
}

func TestImportPathIgnored(t *testing.T) {
	literals := extractSource(t, "import_path.ts", `import thing from "Sign in";`, 8)
	if len(literals) != 0 {
		t.Fatalf("expected no literals, got %#v", literals)
	}
}

func TestRequirePathIgnored(t *testing.T) {
	literals := extractSource(t, "require_path.js", `const thing = require("Sign in");`, 8)
	if len(literals) != 0 {
		t.Fatalf("expected no literals, got %#v", literals)
	}
}

func TestObjectKeyIgnored(t *testing.T) {
	literals := extractSource(t, "object_key.ts", `const labels = {"Sign in": true};`, 8)
	if len(literals) != 0 {
		t.Fatalf("expected no literals, got %#v", literals)
	}
}

func TestTypeLiteralKeyIgnored(t *testing.T) {
	literals := extractSource(t, "type_literal.ts", `type Labels = {"Sign in": string};`, 8)
	if len(literals) != 0 {
		t.Fatalf("expected no literals, got %#v", literals)
	}
}

func TestJSXTextExtracted(t *testing.T) {
	literals := extractSource(t, "component.tsx", `export function View() { return <button>Sign in</button>; }`, 8)
	requireOneLiteral(t, literals, "Sign in")
}

func TestJSXTextWhitespaceCollapsed(t *testing.T) {
	literals := extractSource(t, "component.tsx", "export function View() { return <p>Hello\n  world</p>; }", 8)
	requireOneLiteral(t, literals, "Hello world")
}

func TestJSXVisibleAttributeExtracted(t *testing.T) {
	literals := extractSource(t, "component.tsx", `export function View() { return <input placeholder="Sign in" />; }`, 8)
	requireOneLiteral(t, literals, "Sign in")
}

func TestJSXNonVisibleAttributeIgnored(t *testing.T) {
	literals := extractSource(t, "component.tsx", `export function View() { return <input data-testid="Sign in" />; }`, 8)
	if len(literals) != 0 {
		t.Fatalf("expected no literals, got %#v", literals)
	}
}

func TestJSXNonVisibleExpressionAttributeIgnored(t *testing.T) {
	literals := extractSource(t, "component.tsx", `export function View() { return <input data-testid={"Sign in"} />; }`, 8)
	if len(literals) != 0 {
		t.Fatalf("expected no literals, got %#v", literals)
	}
}

func extractSource(t *testing.T, name string, source string, minLength int) []Literal {
	t.Helper()
	literals, err := Bytes(name, []byte(source), minLength)
	if err != nil {
		t.Fatal(err)
	}
	return literals
}

func requireOneLiteral(t *testing.T, literals []Literal, value string) {
	t.Helper()
	if len(literals) != 1 {
		t.Fatalf("expected one literal, got %#v", literals)
	}
	if literals[0].Literal != value {
		t.Fatalf("Literal = %q, want %q", literals[0].Literal, value)
	}
}

func TestJavaScriptEscapesDecodeLikeJavaScript(t *testing.T) {
	for _, tt := range []struct {
		source string
		want   string
	}{
		{`const a = "Don\'t have an account?";`, "Don't have an account?"},
		{`const a = 'Say \"hello\" to everyone';`, `Say "hello" to everyone`},
		{"const a = `Use the \\` backtick key`;", "Use the ` backtick key"},
		{"const a = 'Line one \\\ncontinued here';", "Line one continued here"},
		{`const a = '\u{1F600} smiling face here';`, "\U0001F600 smiling face here"},
		{`const a = '😀 smiling face here';`, "\U0001F600 smiling face here"},
		{`const a = 'café au lait \x41BC';`, "café au lait ABC"},
		{`const a = 'Use \- dashes \d freely';`, "Use - dashes d freely"},
	} {
		literals := extractSource(t, "escapes.ts", tt.source, 1)
		requireOneLiteral(t, literals, tt.want)
	}
}

func TestUnquoteJSKeepsMalformedEscapesVerbatim(t *testing.T) {
	if got := unquoteJS(`Ab \x4 and \u12 and \u{} kept`, '\''); got != `Ab \x4 and \u12 and \u{} kept` {
		t.Fatalf("unquoteJS() = %q", got)
	}
}

func TestModuleTypeScriptExtensionsUseTypeScriptGrammar(t *testing.T) {
	for _, path := range []string{"module.mts", "common.cts"} {
		literals := extractSource(t, path, `const label: string = "Sign in now";`, 8)
		requireOneLiteral(t, literals, "Sign in now")
	}
}

func TestRawKeepsWhitespaceForStringsButNotJSXText(t *testing.T) {
	literals := extractSource(t, "raw.tsx", "const a = \"  Sign in  \";\nconst b = <p>\n  Sign   in\n</p>;", 1)
	if len(literals) != 2 {
		t.Fatalf("expected 2 literals, got %#v", literals)
	}
	if literals[0].Raw != "  Sign in  " || literals[0].Literal != "Sign in" {
		t.Fatalf("string literal = %#v", literals[0])
	}
	if literals[1].Raw != "Sign in" {
		t.Fatalf("JSX text Raw = %q, want collapsed", literals[1].Raw)
	}
}
