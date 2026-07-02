package extract

import (
	"bytes"
	"path/filepath"
	"strings"

	"github.com/justasmonkev/i18n-string-check/internal/normalize"
)

// HasCandidateMatch reports whether content may contain a literal whose
// normalized form satisfies worth. It scans the raw bytes for a lexical
// superset of every literal value Bytes can produce, without parsing:
//
//   - every string literal's value is the text between two consecutive
//     unescaped quotes of the same kind, because a string cannot contain an
//     unescaped copy of its own quote;
//   - every substitution-free template literal's value is likewise the text
//     between consecutive unescaped backticks;
//   - every JSX text node's value is a maximal run of bytes containing none
//     of '<', '>', '{', '}', because those characters delimit JSX text.
//
// Extra candidates produced from code between real literals can only cause a
// false positive, which the caller resolves with a full parse. A false result
// therefore guarantees that a full parse would yield no matching literals,
// letting callers skip tree-sitter entirely for clean files.
func HasCandidateMatch(path string, content []byte, minLength int, worth MatchFunc) bool {
	if scanQuoteSpans(content, '\'', minLength, worth) {
		return true
	}
	if scanQuoteSpans(content, '"', minLength, worth) {
		return true
	}
	if scanQuoteSpans(content, '`', minLength, worth) {
		return true
	}
	// Plain .ts files are parsed with the JSX-free TypeScript grammar, so
	// they can never produce JSX text literals.
	if strings.ToLower(filepath.Ext(path)) != ".ts" && scanJSXTextRuns(content, minLength, worth) {
		return true
	}
	return false
}

// scanQuoteSpans feeds every span between consecutive unescaped quote bytes
// through the candidate check. Treating each quote as a potential opener
// keeps the scan a superset of real string literals regardless of which
// quotes actually open strings: junk spans between literals simply fail the
// index lookup. Quotes are located with IndexByte and escapedness is decided
// by backslash parity, so the scan runs at memchr speed.
func scanQuoteSpans(content []byte, quote byte, minLength int, worth MatchFunc) bool {
	previous := -1
	for i := 0; ; i++ {
		offset := bytes.IndexByte(content[i:], quote)
		if offset < 0 {
			return false
		}
		i += offset
		backslashes := 0
		for j := i - 1; j >= 0 && content[j] == '\\'; j-- {
			backslashes++
		}
		if backslashes%2 == 1 {
			continue
		}
		if previous >= 0 && checkQuotedCandidate(content[previous+1:i], quote, minLength, worth) {
			return true
		}
		previous = i
	}
}

func checkQuotedCandidate(raw []byte, quote byte, minLength int, worth MatchFunc) bool {
	// A template containing an unescaped substitution never yields a literal.
	if quote == '`' && hasUnescapedSubstitution(raw) {
		return false
	}
	if bytes.IndexByte(raw, '\\') < 0 {
		return checkCandidateBytes(raw, minLength, worth)
	}
	return checkCandidate(unquoteJS(string(raw), quote), minLength, worth)
}

func hasUnescapedSubstitution(raw []byte) bool {
	for i := 0; i < len(raw); i++ {
		switch raw[i] {
		case '\\':
			i++
		case '$':
			if i+1 < len(raw) && raw[i+1] == '{' {
				return true
			}
		}
	}
	return false
}

// scanJSXTextRuns feeds every maximal run of bytes without JSX structure
// characters through the candidate check. Real JSX text nodes are exactly
// such runs; runs of ordinary code are junk candidates that fail the lookup.
func scanJSXTextRuns(content []byte, minLength int, worth MatchFunc) bool {
	start := 0
	for i := 0; i <= len(content); i++ {
		if i < len(content) {
			switch content[i] {
			case '<', '>', '{', '}':
			default:
				continue
			}
		}
		run := content[start:i]
		start = i + 1
		if checkCandidateBytes(run, minLength, worth) {
			return true
		}
	}
	return false
}

// checkCandidate applies the same length gate and normalization as
// (*walker).visit before consulting the worth filter.
func checkCandidate(value string, minLength int, worth MatchFunc) bool {
	collapsed := normalize.CollapseWhitespace(value)
	if len(collapsed)+strings.Count(collapsed, " ") < minLength {
		return false
	}
	normalized := strings.ToLower(collapsed)
	if normalized == "" {
		return false
	}
	return worth(normalized)
}

// Byte classes for the fast candidate gate below.
const (
	classPlain byte = iota
	classSpace
	classNewlineSpace // whitespace that is not ' ', so collapsing changes it
	classUpper
	classHigh // non-ASCII: fall back to the rune-correct path
)

var byteClasses = func() [256]byte {
	var classes [256]byte
	for _, b := range []byte{'\t', '\n', '\v', '\f', '\r'} {
		classes[b] = classNewlineSpace
	}
	classes[' '] = classSpace
	for b := 'A'; b <= 'Z'; b++ {
		classes[b] = classUpper
	}
	for b := 0x80; b < 0x100; b++ {
		classes[b] = classHigh
	}
	return classes
}()

// checkCandidateBytes is checkCandidate for raw byte spans. For ASCII input
// it computes the length gate without allocating, so the frequent junk spans
// between real literals cost nothing; the normalized string is only built for
// spans that pass the gate.
func checkCandidateBytes(raw []byte, minLength int, worth MatchFunc) bool {
	// The gate below counts each collapsed span at most twice its byte
	// length, so spans shorter than half minLength can never pass.
	if 2*len(raw) < minLength {
		return false
	}
	// Single ASCII pass mirroring CollapseWhitespace + the visit length gate:
	// collapsed length plus one extra count per collapsed space.
	gate := 0
	spaces := 0
	pendingSpace := false
	changed := false
	for _, b := range raw {
		switch byteClasses[b] {
		case classPlain:
		case classSpace:
			if pendingSpace || gate == 0 {
				changed = true
			}
			pendingSpace = gate > 0
			continue
		case classNewlineSpace:
			changed = true
			pendingSpace = gate > 0
			continue
		case classUpper:
			changed = true
		case classHigh:
			return checkCandidate(string(raw), minLength, worth)
		}
		if pendingSpace {
			gate += 2
			spaces++
			pendingSpace = false
		}
		gate++
	}
	if pendingSpace {
		changed = true
	}
	if gate < minLength || gate == 0 {
		return false
	}
	if !changed {
		return worth(string(raw))
	}
	normalized := make([]byte, 0, gate-spaces)
	pendingSpace = false
	for _, b := range raw {
		if byteClasses[b] == classSpace || byteClasses[b] == classNewlineSpace {
			pendingSpace = len(normalized) > 0
			continue
		}
		if pendingSpace {
			normalized = append(normalized, ' ')
			pendingSpace = false
		}
		if 'A' <= b && b <= 'Z' {
			b += 'a' - 'A'
		}
		normalized = append(normalized, b)
	}
	return worth(string(normalized))
}
