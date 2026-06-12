package normalize

import (
	"strings"
	"unicode"
)

// Normalize prepares English strings for v0.1 matching.
func Normalize(value string) string {
	// TODO: Replace with golang.org/x/text/cases.Fold() if/when supporting non-ASCII locale matching.
	return strings.ToLower(CollapseWhitespace(value))
}

// CollapseWhitespace trims the string and collapses every whitespace run into
// a single space, equivalent to strings.Join(strings.Fields(value), " ").
// Most inputs are already collapsed, so it first scans for a violation and
// returns the input unchanged (zero allocations) when none is found.
func CollapseWhitespace(value string) string {
	if value == "" {
		return ""
	}
	previousSpace := true // catches a leading space
	clean := true
	for _, r := range value {
		if r == ' ' {
			if previousSpace {
				clean = false
				break
			}
			previousSpace = true
			continue
		}
		if unicode.IsSpace(r) {
			clean = false
			break
		}
		previousSpace = false
	}
	// previousSpace still set after the loop means a trailing space.
	if clean && !previousSpace {
		return value
	}

	var out strings.Builder
	out.Grow(len(value))
	pendingSpace := false
	for _, r := range value {
		if unicode.IsSpace(r) {
			pendingSpace = out.Len() > 0
			continue
		}
		if pendingSpace {
			out.WriteByte(' ')
			pendingSpace = false
		}
		out.WriteRune(r)
	}
	return out.String()
}

func TrimmedLength(value string) int {
	trimmed := CollapseWhitespace(value)
	return len(trimmed) + strings.Count(trimmed, " ")
}
