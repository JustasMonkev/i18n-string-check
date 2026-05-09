package report

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"

	"github.com/justasmonkev/i18n-string-check/internal/index"
)

func TestTextOutput(t *testing.T) {
	summary := NewSummary([]Finding{{
		File:              "tests/login.spec.ts",
		Line:              42,
		Column:            18,
		Type:              "hardcoded-translation",
		Literal:           "Sign in",
		NormalizedLiteral: "sign in",
		Matches: []index.Match{{
			Key:   "login.button",
			Value: "Sign in",
		}},
	}})

	var out bytes.Buffer
	if err := WriteText(&out, summary); err != nil {
		t.Fatal(err)
	}
	text := out.String()
	for _, want := range []string{
		"hardcoded translation: tests/login.spec.ts:42",
		`literal: "Sign in"`,
		`matches en.json key: "login.button" value: "Sign in"`,
		"1 i18n issues found in 1 files",
	} {
		if !strings.Contains(text, want) {
			t.Fatalf("text output missing %q:\n%s", want, text)
		}
	}
}

func TestTextOutputMultipleKeys(t *testing.T) {
	summary := NewSummary([]Finding{{
		File:              "src/Button.tsx",
		Line:              12,
		Column:            8,
		Type:              "hardcoded-translation",
		Literal:           "Save",
		NormalizedLiteral: "save",
		Matches: []index.Match{
			{Key: "common.save", Value: "Save"},
			{Key: "profile.save", Value: "Save"},
		},
	}})

	var out bytes.Buffer
	if err := WriteText(&out, summary); err != nil {
		t.Fatal(err)
	}
	text := out.String()
	for _, want := range []string{
		"matches multiple en.json keys:",
		`- "common.save" value: "Save"`,
		`- "profile.save" value: "Save"`,
		`fix: replace with the correct t("...") key for this context`,
	} {
		if !strings.Contains(text, want) {
			t.Fatalf("text output missing %q:\n%s", want, text)
		}
	}
}

func TestTextOutputTestValueMismatch(t *testing.T) {
	summary := NewSummary([]Finding{{
		File:              "tests/login.spec.ts",
		Line:              42,
		Column:            18,
		Type:              "test-value-mismatch",
		Literal:           "Sign in",
		NormalizedLiteral: "sign in",
		Matches: []index.Match{{
			Key:   "login.button",
			Value: "sign in",
		}},
	}})

	var out bytes.Buffer
	if err := WriteText(&out, summary); err != nil {
		t.Fatal(err)
	}
	text := out.String()
	for _, want := range []string{
		"translation value mismatch: tests/login.spec.ts:42",
		`literal: "Sign in"`,
		`matches en.json key: "login.button" value: "sign in"`,
		`fix: update the test literal to the current en.json value for "login.button"`,
	} {
		if !strings.Contains(text, want) {
			t.Fatalf("text output missing %q:\n%s", want, text)
		}
	}
}

func TestTextOutputLikelyStaleHardcodedTranslation(t *testing.T) {
	summary := NewSummary([]Finding{{
		File:              "src/Login.tsx",
		Line:              12,
		Column:            8,
		Type:              "changed-translation-value",
		Literal:           "Hello my name is Justas, And I am Human",
		NormalizedLiteral: "hello my name is justas, and i am human",
		Matches: []index.Match{{
			Key:   "login.title",
			Value: "Hello my name is Justas, And I am Human, I am QA too",
			Score: 0.82,
			Why:   "source string is contained in the current translation value; 82% word overlap",
		}},
	}})

	var out bytes.Buffer
	if err := WriteText(&out, summary); err != nil {
		t.Fatal(err)
	}
	text := out.String()
	for _, want := range []string{
		"likely stale hardcoded translation: src/Login.tsx:12",
		"  current code string:",
		`    "Hello my name is Justas, And I am Human"`,
		"  similar en.json value:",
		`    key: "login.title"`,
		`    value: "Hello my name is Justas, And I am Human, I am QA too"`,
		"  similarity: 82%",
		"  why: source string is contained in the current translation value; 82% word overlap",
		`  fix: replace with t("login.title"), or mark this literal intentional`,
	} {
		if !strings.Contains(text, want) {
			t.Fatalf("text output missing %q:\n%s", want, text)
		}
	}
}

func TestJSONOutput(t *testing.T) {
	summary := NewSummary([]Finding{{
		File:              "tests/login.spec.ts",
		Line:              42,
		Column:            18,
		Type:              "hardcoded-translation",
		Literal:           "Sign in",
		NormalizedLiteral: "sign in",
		Matches: []index.Match{{
			Key:   "login.button",
			Value: "Sign in",
		}},
	}})

	var out bytes.Buffer
	if err := WriteJSON(&out, summary); err != nil {
		t.Fatal(err)
	}
	var decoded Summary
	if err := json.Unmarshal(out.Bytes(), &decoded); err != nil {
		t.Fatal(err)
	}
	if !decoded.Found || decoded.Count != 1 || decoded.Files != 1 {
		t.Fatalf("decoded summary = %#v", decoded)
	}
}
