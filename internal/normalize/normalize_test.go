package normalize

import "testing"

func TestNormalizeTrimsAndLowercases(t *testing.T) {
	got := Normalize("  SIGN IN  ")
	if got != "sign in" {
		t.Fatalf("Normalize() = %q, want %q", got, "sign in")
	}
}

func TestNormalizeCollapsesWhitespace(t *testing.T) {
	got := Normalize("Hello\n\t  world")
	if got != "hello world" {
		t.Fatalf("Normalize() = %q, want %q", got, "hello world")
	}
}

func TestNormalizeHandlesUnicodeCase(t *testing.T) {
	got := Normalize("CAFÉ")
	if got != "café" {
		t.Fatalf("Normalize() = %q, want %q", got, "café")
	}
}

func TestTrimmedLength(t *testing.T) {
	got := TrimmedLength("  OK  ")
	if got != 2 {
		t.Fatalf("TrimmedLength() = %d, want 2", got)
	}
}

func TestTrimmedLengthCountsSpaceSeparatedPhrasesConservatively(t *testing.T) {
	got := TrimmedLength("Sign in")
	if got != 8 {
		t.Fatalf("TrimmedLength() = %d, want 8", got)
	}
}

func TestTrimmedLengthCollapsesWhitespaceBeforeCounting(t *testing.T) {
	got := TrimmedLength("Sign\n\t  in")
	if got != 8 {
		t.Fatalf("TrimmedLength() = %d, want 8", got)
	}
}
