package extract

import "testing"

// collectCandidates runs HasCandidateMatch with a worth filter that records
// every candidate instead of matching.
func collectCandidates(path string, source string, minLength int) map[string]bool {
	seen := map[string]bool{}
	HasCandidateMatch(path, []byte(source), minLength, func(normalized string) bool {
		seen[normalized] = true
		return false
	})
	return seen
}

// TestFastScanCoversExtractedLiterals is the load-bearing property: every
// literal the full parser extracts must also surface as a fast-scan
// candidate, otherwise the pre-scan could skip files with findings.
func TestFastScanCoversExtractedLiterals(t *testing.T) {
	sources := map[string]string{
		"strings.ts": `const a = "Sign in to your account";
const b = 'It\'s time to sign in';
const c = "He said \"hello\" to everyone";
const tpl = ` + "`Your report is ready`" + `;
const nested = ` + "`head ${`Inner template text here`} tail`" + `;
const priceTpl = ` + "`cost \\${amount} dollars today`" + `;`,
		"component.tsx": `export function View() {
  return (
    <div title="Changes were saved automatically">
      <p>Don't worry about a thing</p>
      <p>Hello
        world spanning lines</p>
      <input placeholder="Enter your email address" />
      <span>{'Braced expression string'}</span>
    </div>
  );
}`,
		"mixed.jsx": `const re = "no regex here";
export const V = () => <p>Apostrophes don't break scanning</p>;
const after = "String after the JSX text";`,
	}
	for path, source := range sources {
		literals, err := Bytes(path, []byte(source), 8)
		if err != nil {
			t.Fatalf("%s: %v", path, err)
		}
		if len(literals) == 0 {
			t.Fatalf("%s: expected literals from full parse", path)
		}
		candidates := collectCandidates(path, source, 8)
		for _, literal := range literals {
			if !candidates[literal.NormalizedLiteral] {
				t.Errorf("%s: extracted literal %q missing from fast-scan candidates %v", path, literal.NormalizedLiteral, candidates)
			}
		}
	}
}

func TestFastScanSkipsSubstitutionTemplates(t *testing.T) {
	candidates := collectCandidates("t.ts", "const a = `Sign in ${name} now please`;", 8)
	if candidates["sign in ${name} now please"] {
		t.Fatalf("substitution template should not be a candidate: %v", candidates)
	}
}

func TestFastScanHonorsMinLength(t *testing.T) {
	candidates := collectCandidates("t.ts", `const a = "short";`, 8)
	if len(candidates) != 0 {
		t.Fatalf("expected no candidates, got %v", candidates)
	}
}

func TestFastScanNormalizesCandidates(t *testing.T) {
	candidates := collectCandidates("t.tsx", "const a = \"SIGN IN\tNOW  Please\";", 8)
	if !candidates["sign in now please"] {
		t.Fatalf("expected collapsed lowercase candidate, got %v", candidates)
	}
}

func TestFastScanNonASCIICandidates(t *testing.T) {
	candidates := collectCandidates("t.ts", `const a = "Zeichenkette mit Ümlauten größer";`, 8)
	if !candidates["zeichenkette mit ümlauten größer"] {
		t.Fatalf("expected non-ASCII candidate, got %v", candidates)
	}
}

func TestFastScanSkipsJSXRunsForPlainTypeScript(t *testing.T) {
	// Plain .ts parses with the JSX-free grammar, so bare text between
	// angle brackets can never be a literal and must not become a candidate.
	source := "const ok = 1 < 2;\nlet fine = true; // Sign in to your account maybe > not text\n"
	candidates := collectCandidates("t.ts", source, 8)
	for candidate := range candidates {
		if candidate == "sign in to your account maybe" {
			t.Fatalf("unexpected jsx-text candidate in .ts file: %v", candidates)
		}
	}
}

func TestFastScanReportsMatch(t *testing.T) {
	source := `const a = "Sign in to your account";`
	matched := HasCandidateMatch("t.ts", []byte(source), 8, func(normalized string) bool {
		return normalized == "sign in to your account"
	})
	if !matched {
		t.Fatal("expected fast scan to report a match")
	}
	matched = HasCandidateMatch("t.ts", []byte(source), 8, func(string) bool { return false })
	if matched {
		t.Fatal("expected no match when the filter rejects everything")
	}
}
