package main

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestRunExitCodeFound(t *testing.T) {
	dir := fixtureProject(t, `"Sign in"`)
	code, output := runBinary(t, dir, filepath.Join(dir, "en.json"), filepath.Join(dir, "src"))
	if code != 1 {
		t.Fatalf("exit code = %d, want 1; output:\n%s", code, output)
	}
	if !strings.Contains(output, "hardcoded translation") {
		t.Fatalf("output missing finding:\n%s", output)
	}
}

func TestRunExitCodeNoFindings(t *testing.T) {
	dir := fixtureProject(t, `t("login.button")`)
	code, output := runBinary(t, dir, filepath.Join(dir, "en.json"), filepath.Join(dir, "src"))
	if code != 0 {
		t.Fatalf("exit code = %d, want 0; output:\n%s", code, output)
	}
}

func TestRunTestModeAllowsExactDirectString(t *testing.T) {
	dir := fixtureProject(t, `"Sign in"`)
	code, output := runBinary(t, dir, filepath.Join(dir, "en.json"), filepath.Join(dir, "src"), "--mode=test")
	if code != 0 {
		t.Fatalf("exit code = %d, want 0; output:\n%s", code, output)
	}
}

func TestRunTestModeFlagsCaseMismatch(t *testing.T) {
	dir := fixtureProjectWithEN(t, `{"login.button":"sign in"}`, `"Sign in"`)
	code, output := runBinary(t, dir, filepath.Join(dir, "en.json"), filepath.Join(dir, "src"), "--mode=test")
	if code != 1 {
		t.Fatalf("exit code = %d, want 1; output:\n%s", code, output)
	}
	if !strings.Contains(output, "translation value mismatch") {
		t.Fatalf("output missing mismatch:\n%s", output)
	}
}

func TestRunTestModeCannotDetectRemovedOldValue(t *testing.T) {
	dir := fixtureProjectWithEN(t, `{"login.button":"Log in"}`, `"Sign in"`)
	code, output := runBinary(t, dir, filepath.Join(dir, "en.json"), filepath.Join(dir, "src"), "--mode=test")
	if code != 0 {
		t.Fatalf("exit code = %d, want 0; output:\n%s", code, output)
	}
}

func TestRunSimilarityFlagsChangedHardcodedValue(t *testing.T) {
	dir := fixtureProjectWithEN(t, `{"login.title":"Hello my name is Justas, And I am Human, I am QA too"}`, `"Hello my name is Justas, And I am Human"`)

	code, output := runBinary(t, dir, filepath.Join(dir, "en.json"), filepath.Join(dir, "src"), "--similarity-flow")
	if code != 1 {
		t.Fatalf("exit code = %d, want 1; output:\n%s", code, output)
	}
	for _, want := range []string{
		"likely stale hardcoded translation",
		"current code string:",
		`"Hello my name is Justas, And I am Human"`,
		"similar en.json value:",
		`key: "login.title"`,
		`value: "Hello my name is Justas, And I am Human, I am QA too"`,
		"similarity: 82%",
		"why: source string is contained in the current translation value; 82% word overlap",
		`fix: replace with t("login.title"), or mark this literal intentional`,
	} {
		if !strings.Contains(output, want) {
			t.Fatalf("output missing %q:\n%s", want, output)
		}
	}
}

func TestRunSimilarityIgnoresShortDifferentString(t *testing.T) {
	dir := fixtureProjectWithEN(t, `{"login.button":"Log in"}`, `"Sign in"`)
	code, output := runBinary(t, dir, filepath.Join(dir, "en.json"), filepath.Join(dir, "src"), "--similarity-flow")
	if code != 0 {
		t.Fatalf("exit code = %d, want 0; output:\n%s", code, output)
	}
}

func TestRunSimilarityFlowFixtureRequiresFlag(t *testing.T) {
	dir := similarityFixtureProject(t)
	code, output := runBinary(t, dir, filepath.Join(dir, "en.json"), filepath.Join(dir, "src"))
	if code != 0 {
		t.Fatalf("exit code = %d, want 0; output:\n%s", code, output)
	}
	if strings.Contains(output, "likely stale hardcoded translation") {
		t.Fatalf("output contains similarity finding without flag:\n%s", output)
	}
}

func TestRunSimilarityFlowFixtureWithFlag(t *testing.T) {
	dir := similarityFixtureProject(t)
	code, output := runBinary(t, dir, filepath.Join(dir, "en.json"), filepath.Join(dir, "src"), "--similarity-flow")
	if code != 1 {
		t.Fatalf("exit code = %d, want 1; output:\n%s", code, output)
	}

	for _, want := range []string{
		"LoginTitle.tsx",
		`key: "login.title"`,
		"WorkspaceInvite.tsx",
		`key: "workspace.invite"`,
		"ReportReady.tsx",
		`key: "report.ready"`,
	} {
		if !strings.Contains(output, want) {
			t.Fatalf("output missing %q:\n%s", want, output)
		}
	}
	for _, unwanted := range []string{
		"PasswordUpdated.tsx",
		"ShortBiometricCopy.tsx",
		`key: "auth.biometric"`,
	} {
		if strings.Contains(output, unwanted) {
			t.Fatalf("output unexpectedly contains %q:\n%s", unwanted, output)
		}
	}
}

func TestRunRejectsInvalidMode(t *testing.T) {
	dir := fixtureProject(t, `"Sign in"`)
	code, output := runBinary(t, dir, filepath.Join(dir, "en.json"), filepath.Join(dir, "src"), "--mode=unknown")
	if code != 2 {
		t.Fatalf("exit code = %d, want 2; output:\n%s", code, output)
	}
}

func TestRunNestedJSONFindsFlattenedKey(t *testing.T) {
	dir := fixtureProjectWithEN(t, `{"login":{"button":"Sign in"}}`, `"Sign in"`)

	code, output := runBinary(t, dir, filepath.Join(dir, "en.json"), filepath.Join(dir, "src"))
	if code != 1 {
		t.Fatalf("exit code = %d, want 1; output:\n%s", code, output)
	}
	if !strings.Contains(output, `matches en.json key: "login.button"`) {
		t.Fatalf("output missing flattened key:\n%s", output)
	}
}

func TestRunJSONOutput(t *testing.T) {
	dir := fixtureProject(t, `"Sign in"`)
	code, output := runBinary(t, dir, filepath.Join(dir, "en.json"), filepath.Join(dir, "src"), "--json")
	if code != 1 {
		t.Fatalf("exit code = %d, want 1; output:\n%s", code, output)
	}
	var decoded struct {
		Found    bool `json:"found"`
		Count    int  `json:"count"`
		Findings []struct {
			Literal string `json:"literal"`
		} `json:"findings"`
	}
	if err := json.Unmarshal([]byte(output), &decoded); err != nil {
		t.Fatalf("invalid JSON output: %v\n%s", err, output)
	}
	if !decoded.Found || decoded.Count != 1 || decoded.Findings[0].Literal != "Sign in" {
		t.Fatalf("decoded output = %#v", decoded)
	}
}

func TestRunUsesProjectConfigFile(t *testing.T) {
	dir := fixtureProject(t, `"Sign in"`)
	if err := os.WriteFile(filepath.Join(dir, ".i18n-string-check.json"), []byte(`{"minLength":20}`), 0o644); err != nil {
		t.Fatal(err)
	}

	code, output := runBinary(t, dir, filepath.Join(dir, "en.json"), filepath.Join(dir, "src"))
	if code != 0 {
		t.Fatalf("exit code = %d, want 0; output:\n%s", code, output)
	}
}

func TestRunIgnoresLiteralWithInlineIgnoreComment(t *testing.T) {
	dir := fixtureProjectWithFiles(t, `{"login.button":"Sign in"}`, map[string]string{
		"login.ts": `// i18n-string-check-ignore
const label = "Sign in";`,
	})

	code, output := runBinary(t, dir, filepath.Join(dir, "en.json"), filepath.Join(dir, "src"))
	if code != 0 {
		t.Fatalf("exit code = %d, want 0; output:\n%s", code, output)
	}
}

func TestRunBaselineSuppressesExistingFinding(t *testing.T) {
	dir := fixtureProject(t, `"Sign in"`)
	baseline := filepath.Join(dir, "i18n-string-check-baseline.json")
	if err := os.WriteFile(baseline, []byte(`{
		"findings": [{
			"file": "src/login.ts",
			"type": "hardcoded-translation",
			"literal": "Sign in",
			"matches": [{"key": "login.button", "value": "Sign in"}]
		}]
	}`), 0o644); err != nil {
		t.Fatal(err)
	}

	code, output := runBinary(t, dir, filepath.Join(dir, "en.json"), filepath.Join(dir, "src"), "--baseline", baseline)
	if code != 0 {
		t.Fatalf("exit code = %d, want 0; output:\n%s", code, output)
	}
}

func TestRunFlagsInterpolatedTranslationPattern(t *testing.T) {
	dir := fixtureProjectWithEN(t, `{"profile.greeting":"Hello, {name}"}`, `"Hello, Bob"`)

	code, output := runBinary(t, dir, filepath.Join(dir, "en.json"), filepath.Join(dir, "src"))
	if code != 1 {
		t.Fatalf("exit code = %d, want 1; output:\n%s", code, output)
	}
	if !strings.Contains(output, `matches en.json key: "profile.greeting" value: "Hello, {name}"`) {
		t.Fatalf("output missing interpolation match:\n%s", output)
	}
}

func TestRunFlagsPluralTranslationPatterns(t *testing.T) {
	dir := fixtureProjectWithFiles(t, `{
		"cart": {
			"item_one": "{count} item",
			"item_other": "{count} items"
		},
		"invite": "{count, plural, one {# invite} other {# invites}}"
	}`, map[string]string{
		"cart.ts":   `const label = "2 items";`,
		"invite.ts": `const label = "3 invites";`,
	})

	code, output := runBinary(t, dir, filepath.Join(dir, "en.json"), filepath.Join(dir, "src"))
	if code != 1 {
		t.Fatalf("exit code = %d, want 1; output:\n%s", code, output)
	}
	for _, want := range []string{
		`matches en.json key: "cart.item_other" value: "{count} items"`,
		`matches en.json key: "invite" value: "{count, plural, one {# invite} other {# invites}}"`,
	} {
		if !strings.Contains(output, want) {
			t.Fatalf("output missing %q:\n%s", want, output)
		}
	}
}

func fixtureProject(t *testing.T, source string) string {
	t.Helper()
	return fixtureProjectWithEN(t, `{"login.button":"Sign in"}`, source)
}

func fixtureProjectWithEN(t *testing.T, enJSON string, source string) string {
	t.Helper()
	return fixtureProjectWithFiles(t, enJSON, map[string]string{"login.ts": "const label = " + source + ";\n"})
}

func similarityFixtureProject(t *testing.T) string {
	t.Helper()
	return fixtureProjectWithFiles(t, `{
		"login.title": "Hello my name is Justas, And I am Human, I am QA too",
		"workspace.invite": "Invite your teammates to review the workspace access request before Friday",
		"report.ready": "Your monthly compliance report is ready for review in the dashboard",
		"auth.biometric": "Sign in using biometrics"
	}`, map[string]string{
		"LoginTitle.tsx":         `const label = "Hello my name is Justas, And I am Human";`,
		"WorkspaceInvite.tsx":    `const label = "Invite your teammates to review the workspace access request";`,
		"ReportReady.tsx":        `const label = "Your monthly compliance report is ready for review";`,
		"PasswordUpdated.tsx":    `const label = "Your password was updated";`,
		"ShortBiometricCopy.tsx": `const label = "Sign in using MP";`,
	})
}

func fixtureProjectWithFiles(t *testing.T, enJSON string, files map[string]string) string {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "en.json"), []byte(enJSON), 0o644); err != nil {
		t.Fatal(err)
	}
	src := filepath.Join(dir, "src")
	if err := os.Mkdir(src, 0o755); err != nil {
		t.Fatal(err)
	}
	for name, content := range files {
		path := filepath.Join(src, name)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(content+"\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func runBinary(t *testing.T, dir string, args ...string) (int, string) {
	t.Helper()
	binary := filepath.Join(t.TempDir(), "i18n-string-check")
	if runtime.GOOS == "windows" {
		binary += ".exe"
	}
	build := exec.Command("go", "build", "-o", binary, ".")
	build.Dir = "."
	if out, err := build.CombinedOutput(); err != nil {
		t.Fatalf("go build failed: %v\n%s", err, out)
	}

	cmd := exec.Command(binary, args...)
	cmd.Dir = dir
	out, err := cmd.CombinedOutput()
	if err == nil {
		return 0, string(out)
	}
	var exitErr *exec.ExitError
	if ok := errorAs(err, &exitErr); ok {
		return exitErr.ExitCode(), string(out)
	}
	t.Fatalf("run failed: %v\n%s", err, out)
	return -1, ""
}

func errorAs(err error, target any) bool {
	switch t := target.(type) {
	case **exec.ExitError:
		exitErr, ok := err.(*exec.ExitError)
		if ok {
			*t = exitErr
		}
		return ok
	default:
		return false
	}
}

func TestRunFlagsJSXTextNextToCharacterReference(t *testing.T) {
	dir := fixtureProjectWithFiles(t, `{"legal.terms":"Terms and conditions"}`, map[string]string{
		"Footer.tsx": `export const Footer = () => <p>Terms and conditions &amp; privacy</p>;`,
	})
	code, output := runBinary(t, dir, filepath.Join(dir, "en.json"), filepath.Join(dir, "src"))
	if code != 1 || !strings.Contains(output, `key: "legal.terms"`) {
		t.Fatalf("exit code = %d, want 1 with legal.terms finding; output:\n%s", code, output)
	}
}

func TestRunFlagsEscapedApostropheInDoubleQuotedString(t *testing.T) {
	dir := fixtureProjectWithEN(t, `{"auth.noAccount":"Don't have an account?"}`, `"Don\'t have an account?"`)
	code, output := runBinary(t, dir, filepath.Join(dir, "en.json"), filepath.Join(dir, "src"))
	if code != 1 || !strings.Contains(output, `key: "auth.noAccount"`) {
		t.Fatalf("exit code = %d, want 1 with auth.noAccount finding; output:\n%s", code, output)
	}
}

func TestRunTestModeFlagsSurroundingWhitespaceMismatch(t *testing.T) {
	dir := fixtureProject(t, `"  Sign in  "`)
	code, output := runBinary(t, dir, filepath.Join(dir, "en.json"), filepath.Join(dir, "src"), "--mode=test")
	if code != 1 || !strings.Contains(output, "translation value mismatch") {
		t.Fatalf("exit code = %d, want 1 with mismatch; output:\n%s", code, output)
	}
}

func TestRunTestModeAllowsExactMultilineValue(t *testing.T) {
	dir := fixtureProjectWithEN(t, `{"help.body":"First line\nsecond line"}`, `"First line\nsecond line"`)
	code, output := runBinary(t, dir, filepath.Join(dir, "en.json"), filepath.Join(dir, "src"), "--mode=test")
	if code != 0 {
		t.Fatalf("exit code = %d, want 0; output:\n%s", code, output)
	}
}

func TestRunPluralBranchesInSourceAndTestMode(t *testing.T) {
	en := `{"cart":"{count, plural, =0 {Your cart is empty} one {One item in cart} other {# items in cart}}"}`
	dir := fixtureProjectWithFiles(t, en, map[string]string{
		"Cart.TSX": `export const Cart = () => <p>Your cart is empty</p>;`,
		"cart.ts":  `const a = "One item in cart"; const b = "one item in cart";`,
	})
	code, output := runBinary(t, dir, filepath.Join(dir, "en.json"), filepath.Join(dir, "src"), "--json")
	if code != 1 {
		t.Fatalf("source mode exit code = %d, want 1; output:\n%s", code, output)
	}
	var summary struct{ Count int }
	if err := json.Unmarshal([]byte(output), &summary); err != nil || summary.Count != 3 {
		t.Fatalf("source mode count = %d (err %v), want 3 (Cart.TSX + both cart.ts literals); output:\n%s", summary.Count, err, output)
	}
	if !strings.Contains(output, `"variant": "Your cart is empty"`) {
		t.Fatalf("JSON output missing variant:\n%s", output)
	}

	// Test mode accepts the exact branch text and flags only the case drift.
	code, output = runBinary(t, dir, filepath.Join(dir, "en.json"), filepath.Join(dir, "src"), "--mode=test", "--json")
	if err := json.Unmarshal([]byte(output), &summary); err != nil || code != 1 || summary.Count != 1 || !strings.Contains(output, `"literal": "one item in cart"`) {
		t.Fatalf("test mode exit=%d count=%d, want 1 finding for the lowercase literal; output:\n%s", code, summary.Count, output)
	}
}

func TestRunOutputIsDeterministic(t *testing.T) {
	en := `{"a.b":"Flat dotted value here","a":{"b":"Nested object value here"},
		"x.save":"Save changes","y.save":"Save changes","z.save":"Save changes"}`
	dir := fixtureProjectWithEN(t, en, `["Flat dotted value here", "Nested object value here", "Save changes"]`)
	_, first := runBinary(t, dir, filepath.Join(dir, "en.json"), filepath.Join(dir, "src"))
	for _, want := range []string{`value: "Flat dotted value here"`, `value: "Nested object value here"`} {
		if !strings.Contains(first, want) {
			t.Fatalf("output missing %s:\n%s", want, first)
		}
	}
	for range 10 {
		if _, again := runBinary(t, dir, filepath.Join(dir, "en.json"), filepath.Join(dir, "src")); again != first {
			t.Fatalf("output changed between runs:\n%s\n---\n%s", first, again)
		}
	}
}
