package extract

import (
	"encoding/json"
	"math/rand/v2"
	"os/exec"
	"strings"
	"testing"
)

// TestUnquoteMatchesNodeOracle decodes randomly generated JavaScript string
// and template literals with both this package and Node.js, which is the
// reference implementation of JavaScript escape semantics. It is skipped
// when node is not installed or in -short mode.
func TestUnquoteMatchesNodeOracle(t *testing.T) {
	if testing.Short() {
		t.Skip("oracle test skipped in -short mode")
	}
	node, err := exec.LookPath("node")
	if err != nil {
		t.Skip("node not installed")
	}
	common := []string{"a", "Z", " ", "  ", "é", "😀", `\n`, `\t`, `\r`, `\b`, `\f`, `\v`, `\\`,
		`\'`, `\"`, "\\`", `\x41`, `\x7e`, `é`, `\u{1F600}`, `\u{41}`, `\u{0}`, `😀`,
		`\-`, `\d`, `\q`, `\$`, "\\\n", "\\\r\n", "\\ ", `\0`, " ", "{", "}", "$"}
	octal := []string{`\101`, `\7`, `\08`, `\377`, `\400`, `\18`}

	rng := rand.New(rand.NewPCG(1, 2))
	var sources []string
	for i := 0; i < 3000; i++ {
		quote := []byte{'\'', '"', '`'}[i%3]
		pieces := common
		if quote != '`' {
			pieces = append(append([]string{}, common...), octal...)
		}
		var body strings.Builder
		body.WriteString("Z")
		for range 1 + rng.IntN(8) {
			piece := pieces[rng.IntN(len(pieces))]
			if piece == string(quote) || (quote == '`' && piece == "$") {
				continue
			}
			body.WriteString(piece)
		}
		sources = append(sources, string(quote)+body.String()+string(quote))
	}

	script := "console.log(JSON.stringify([" + strings.Join(sources, ",\n") + "]))"
	out, err := exec.Command(node, "-e", script).CombinedOutput()
	if err != nil {
		t.Fatalf("node failed: %v\n%s", err, out)
	}
	var want []string
	if err := json.Unmarshal(out, &want); err != nil {
		t.Fatalf("decode node output: %v", err)
	}
	checked := 0
	for i, source := range sources {
		literals, err := Bytes("oracle.js", []byte("x = "+source+";"), 1)
		if err != nil {
			continue // tree-sitter rejects a few escapes Node accepts
		}
		if len(literals) != 1 {
			t.Fatalf("%s: got %d literals", source, len(literals))
		}
		if literals[0].Raw != want[i] {
			t.Fatalf("%s: decoded %q, node says %q", source, literals[0].Raw, want[i])
		}
		checked++
	}
	if checked < len(sources)*9/10 {
		t.Fatalf("only %d of %d cases parsed", checked, len(sources))
	}
	t.Logf("%d of %d literals match node", checked, len(sources))
}
