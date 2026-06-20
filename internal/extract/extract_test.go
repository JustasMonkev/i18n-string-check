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

func TestModernModuleExtensionsUseMatchingParsers(t *testing.T) {
	for _, name := range []string{"module.mts", "module.cts", "module.mjs", "module.cjs"} {
		t.Run(name, func(t *testing.T) {
			literals := extractSource(t, name, `const label = "Sign in";`, 8)
			requireOneLiteral(t, literals, "Sign in")
		})
	}
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
