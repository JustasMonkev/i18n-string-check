package normalize

import "strings"

// Normalize prepares English strings for v0.1 matching.
func Normalize(value string) string {
	// TODO: Replace with golang.org/x/text/cases.Fold() if/when supporting non-ASCII locale matching.
	return strings.ToLower(CollapseWhitespace(value))
}

func CollapseWhitespace(value string) string {
	return strings.Join(strings.Fields(value), " ")
}

func TrimmedLength(value string) int {
	trimmed := CollapseWhitespace(value)
	return len(trimmed) + strings.Count(trimmed, " ")
}
