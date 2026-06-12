package index

import (
	"encoding/json"
	"fmt"
	"os"
	"regexp"
	"sort"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/justasmonkev/i18n-string-check/internal/normalize"
)

type Match struct {
	Key             string  `json:"key"`
	Value           string  `json:"value"`
	NormalizedValue string  `json:"-"`
	Reason          string  `json:"reason,omitempty"`
	Score           float64 `json:"score,omitempty"`
	Why             string  `json:"why,omitempty"`
}

type Index struct {
	entries        map[string][]Match
	patterns       []patternMatch
	all            []Match
	// meta holds precomputed similarity data aligned with all; it is only
	// populated for similarity candidates so lookups never re-tokenize or
	// re-count entry values.
	meta           []entryMeta
	similarByToken map[string][]int
}

type entryMeta struct {
	words     map[string]bool
	runeCount int
}

type patternMatch struct {
	match   Match
	pattern *regexp.Regexp
	// prefix is the pattern's literal prefix, used to skip the regex engine
	// for the common non-matching case.
	prefix string
}

func Load(path string, minLength int) (*Index, error) {
	content, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return FromBytes(content, minLength)
}

func FromBytes(content []byte, minLength int) (*Index, error) {
	raw, err := parseTranslations(content)
	if err != nil {
		return nil, err
	}

	idx := &Index{entries: map[string][]Match{}, similarByToken: map[string][]int{}}
	for key, value := range raw {
		if normalize.TrimmedLength(value) < minLength {
			continue
		}
		idx.add(key, value)
	}

	return idx, nil
}

func parseTranslations(content []byte) (map[string]string, error) {
	var raw map[string]any
	if err := json.Unmarshal(content, &raw); err != nil {
		return nil, fmt.Errorf("malformed en.json: %w", err)
	}

	flat := map[string]string{}
	flattenTranslations("", raw, flat)

	return flat, nil
}

func flattenTranslations(prefix string, raw map[string]any, flat map[string]string) {
	for key, value := range raw {
		path := key
		if prefix != "" {
			path = prefix + "." + key
		}
		switch typed := value.(type) {
		case string:
			flat[path] = typed
		case map[string]any:
			flattenTranslations(path, typed, flat)
		default:
			continue
		}
	}
}

func (i *Index) add(key string, value string) {
	normalized := normalize.Normalize(value)
	index := len(i.all)
	match := Match{
		Key:             key,
		Value:           value,
		NormalizedValue: normalized,
	}
	i.entries[normalized] = append(i.entries[normalized], match)
	i.all = append(i.all, match)
	var meta entryMeta
	if similarityCandidate(normalized) {
		meta = entryMeta{
			words:     wordSet(normalized),
			runeCount: utf8.RuneCountInString(normalized),
		}
		for word := range meta.words {
			if len(word) >= 3 {
				i.similarByToken[word] = append(i.similarByToken[word], index)
			}
		}
	}
	i.meta = append(i.meta, meta)
	for _, template := range translationPatternTemplates(value) {
		pattern, ok := compileTranslationPattern(template)
		if ok {
			prefix, _ := pattern.LiteralPrefix()
			i.patterns = append(i.patterns, patternMatch{match: match, pattern: pattern, prefix: prefix})
		}
	}
}

func (i *Index) Lookup(value string) []Match {
	if i == nil {
		return nil
	}
	return i.LookupNormalized(normalize.Normalize(value))
}

// LookupNormalized is Lookup for callers that already hold the normalized form,
// avoiding a redundant re-normalization of the source literal.
func (i *Index) LookupNormalized(normalized string) []Match {
	if i == nil {
		return nil
	}
	matches := i.entries[normalized]
	if len(matches) == 0 {
		return nil
	}
	copied := make([]Match, len(matches))
	copy(copied, matches)
	return copied
}

func (i *Index) LookupPattern(value string) []Match {
	if i == nil {
		return nil
	}
	return i.LookupPatternNormalized(normalize.Normalize(value))
}

// LookupPatternNormalized is LookupPattern for callers that already hold the
// normalized form.
func (i *Index) LookupPatternNormalized(normalized string) []Match {
	if i == nil {
		return nil
	}
	var matches []Match
	for _, candidate := range i.patterns {
		if candidate.prefix != "" && !strings.HasPrefix(normalized, candidate.prefix) {
			continue
		}
		if candidate.pattern.MatchString(normalized) {
			match := candidate.match
			match.Reason = "translation-pattern"
			match.Score = 1
			match.Why = "source string matches the current translation pattern"
			matches = append(matches, match)
		}
	}
	return matches
}

func (i *Index) LookupSimilar(value string) []Match {
	if i == nil {
		return nil
	}
	return i.LookupSimilarNormalized(normalize.Normalize(value))
}

// LookupSimilarNormalized is LookupSimilar for callers that already hold the
// normalized form.
func (i *Index) LookupSimilarNormalized(normalized string) []Match {
	if i == nil {
		return nil
	}
	if !similarityCandidate(normalized) {
		return nil
	}
	queryWords := wordSet(normalized)
	queryRunes := utf8.RuneCountInString(normalized)
	candidateIndexes := i.similarCandidateIndexes(queryRunes, queryWords)
	var matches []Match
	for _, candidateIndex := range candidateIndexes {
		match := i.all[candidateIndex]
		if normalized == match.NormalizedValue {
			continue
		}
		meta := i.meta[candidateIndex]
		details, ok := similarityDetailsPrecomputed(normalized, queryRunes, queryWords, match.NormalizedValue, meta.runeCount, meta.words)
		if ok {
			match.Reason = details.Reason
			match.Score = details.Score
			match.Why = details.Why
			matches = append(matches, match)
		}
	}
	sort.Slice(matches, func(i, j int) bool {
		if matches[i].Score != matches[j].Score {
			return matches[i].Score > matches[j].Score
		}
		return matches[i].Key < matches[j].Key
	})
	if len(matches) > 3 {
		matches = matches[:3]
	}
	return matches
}

func (i *Index) similarCandidateIndexes(queryRunes int, words map[string]bool) []int {
	seen := map[int]bool{}
	for word := range words {
		if len(word) < 3 {
			continue
		}
		for _, index := range i.similarByToken[word] {
			if !seen[index] && likelySimilarLength(queryRunes, i.meta[index].runeCount) {
				seen[index] = true
			}
		}
	}
	indexes := make([]int, 0, len(seen))
	for index := range seen {
		indexes = append(indexes, index)
	}
	sort.Ints(indexes)
	return indexes
}

func likelySimilarLength(aLen int, bLen int) bool {
	if aLen == 0 || bLen == 0 {
		return false
	}
	shorter, longer := aLen, bLen
	if shorter > longer {
		shorter, longer = longer, shorter
	}
	return float64(shorter)/float64(longer) >= 0.5
}

func translationPatternTemplates(value string) []string {
	plurals := icuPluralTemplates(value)
	if len(plurals) > 0 {
		return plurals
	}
	return []string{value}
}

func compileTranslationPattern(template string) (*regexp.Regexp, bool) {
	normalized := normalize.Normalize(template)
	var out strings.Builder
	out.WriteString("^")
	placeholderCount := 0
	literalCount := 0
	for i := 0; i < len(normalized); i++ {
		switch normalized[i] {
		case '{':
			end := strings.IndexByte(normalized[i+1:], '}')
			if end < 0 {
				out.WriteString(regexp.QuoteMeta(normalized[i : i+1]))
				literalCount++
				continue
			}
			content := normalized[i+1 : i+1+end]
			if content == "" || strings.Contains(content, ",") || strings.ContainsAny(content, "{}") {
				return nil, false
			}
			out.WriteString(".+")
			placeholderCount++
			i += end + 1
		case '#':
			out.WriteString(`\d+`)
			placeholderCount++
		default:
			out.WriteString(regexp.QuoteMeta(normalized[i : i+1]))
			if isPatternLiteral(normalized[i]) {
				literalCount++
			}
		}
	}
	out.WriteString("$")
	if placeholderCount == 0 || literalCount < 3 {
		return nil, false
	}
	pattern, err := regexp.Compile(out.String())
	if err != nil {
		return nil, false
	}
	return pattern, true
}

func isPatternLiteral(char byte) bool {
	return (char >= 'a' && char <= 'z') || (char >= '0' && char <= '9')
}

func icuPluralTemplates(value string) []string {
	normalized := normalize.Normalize(value)
	if !strings.Contains(normalized, "plural") {
		return nil
	}
	var templates []string
	for i := 0; i < len(normalized); {
		for i < len(normalized) && !isWordStart(normalized[i]) {
			i++
		}
		start := i
		for i < len(normalized) && isWordPart(normalized[i]) {
			i++
		}
		if start == i {
			continue
		}
		word := normalized[start:i]
		if !isPluralCategory(word) {
			continue
		}
		for i < len(normalized) && normalized[i] == ' ' {
			i++
		}
		if i >= len(normalized) || normalized[i] != '{' {
			continue
		}
		body, next, ok := balancedBraces(normalized, i)
		if ok {
			templates = append(templates, body)
			i = next
		}
	}
	return templates
}

func balancedBraces(value string, start int) (string, int, bool) {
	depth := 0
	for i := start; i < len(value); i++ {
		switch value[i] {
		case '{':
			depth++
		case '}':
			depth--
			if depth == 0 {
				return value[start+1 : i], i + 1, true
			}
		}
	}
	return "", start, false
}

func isPluralCategory(value string) bool {
	switch value {
	case "zero", "one", "two", "few", "many", "other":
		return true
	default:
		return false
	}
}

func isWordStart(char byte) bool {
	return char >= 'a' && char <= 'z'
}

func isWordPart(char byte) bool {
	return isWordStart(char) || char == '_'
}

func HasExactValue(matches []Match, value string) bool {
	for _, match := range matches {
		if match.Value == value {
			return true
		}
	}
	return false
}

func similarityCandidate(value string) bool {
	return utf8.RuneCountInString(value) >= 24 && countFields(value) >= 5
}

// countFields counts whitespace-separated fields without allocating, matching
// the semantics of len(strings.Fields(value)) on the hot similarity path.
func countFields(value string) int {
	count := 0
	inField := false
	for _, r := range value {
		if unicode.IsSpace(r) {
			inField = false
			continue
		}
		if !inField {
			inField = true
			count++
		}
	}
	return count
}

type similarityDetailsResult struct {
	Reason string
	Score  float64
	Why    string
}

// similarityDetailsPrecomputed reports how similar query a is to candidate b.
// Both sides are already known to be similarity candidates, and word sets and
// rune counts are precomputed so the per-candidate cost stays low. The
// expensive Levenshtein distance only runs when the cheap word-overlap and
// length-ratio bounds show its threshold is still reachable: the edit
// similarity can never exceed shorterLen/longerLen.
func similarityDetailsPrecomputed(a string, aRunes int, aWords map[string]bool, b string, bRunes int, bWords map[string]bool) (similarityDetailsResult, bool) {
	shorter, longer := a, b
	shorterLen, longerLen := aRunes, bRunes
	bIsLonger := true
	if aRunes > bRunes {
		shorter, longer = b, a
		shorterLen, longerLen = bRunes, aRunes
		bIsLonger = false
	}
	lengthRatio := float64(shorterLen) / float64(longerLen)
	wordOverlap := wordOverlapRatioWithWords(aWords, bWords)
	if lengthRatio >= 0.65 && strings.Contains(longer, shorter) {
		score := maxFloat(wordOverlap, lengthRatio)
		why := fmt.Sprintf("%d%% word overlap", percent(wordOverlap))
		if bIsLonger {
			why = "source string is contained in the current translation value; " + why
		} else {
			why = "current translation value is contained in the source string; " + why
		}
		return similarityDetailsResult{
			Reason: "contained-substring",
			Score:  score,
			Why:    why,
		}, true
	}
	if wordOverlap >= 0.5 && lengthRatio >= 0.78 {
		editSimilarity := levenshteinRatio(a, b)
		if editSimilarity >= 0.78 {
			return similarityDetailsResult{
				Reason: "edit-similarity",
				Score:  editSimilarity,
				Why:    fmt.Sprintf("%d%% edit similarity with %d%% word overlap", percent(editSimilarity), percent(wordOverlap)),
			}, true
		}
	}
	if wordOverlap >= 0.7 {
		return similarityDetailsResult{
			Reason: "word-overlap",
			Score:  wordOverlap,
			Why:    fmt.Sprintf("%d%% word overlap", percent(wordOverlap)),
		}, true
	}
	return similarityDetailsResult{}, false
}

func wordOverlapRatioWithWords(aWords map[string]bool, bWords map[string]bool) float64 {
	if len(aWords) == 0 || len(bWords) == 0 {
		return 0
	}
	intersection := 0
	for word := range aWords {
		if bWords[word] {
			intersection++
		}
	}
	denominator := len(aWords)
	if len(bWords) > denominator {
		denominator = len(bWords)
	}
	return float64(intersection) / float64(denominator)
}

func wordSet(value string) map[string]bool {
	out := map[string]bool{}
	for _, word := range strings.FieldsFunc(value, func(r rune) bool {
		return !unicode.IsLetter(r) && !unicode.IsDigit(r)
	}) {
		out[word] = true
	}
	return out
}

func levenshteinRatio(a string, b string) float64 {
	aRunes := []rune(a)
	bRunes := []rune(b)
	maxLen := len(aRunes)
	if len(bRunes) > maxLen {
		maxLen = len(bRunes)
	}
	if maxLen == 0 {
		return 1
	}
	return 1 - float64(levenshteinDistance(aRunes, bRunes))/float64(maxLen)
}

func levenshteinDistance(a []rune, b []rune) int {
	if len(a) == 0 {
		return len(b)
	}
	if len(b) == 0 {
		return len(a)
	}

	previous := make([]int, len(b)+1)
	current := make([]int, len(b)+1)
	for j := range previous {
		previous[j] = j
	}

	for i := 1; i <= len(a); i++ {
		current[0] = i
		for j := 1; j <= len(b); j++ {
			cost := 0
			if a[i-1] != b[j-1] {
				cost = 1
			}
			current[j] = minInt(
				previous[j]+1,
				current[j-1]+1,
				previous[j-1]+cost,
			)
		}
		previous, current = current, previous
	}

	return previous[len(b)]
}

func minInt(values ...int) int {
	minimum := values[0]
	for _, value := range values[1:] {
		if value < minimum {
			minimum = value
		}
	}
	return minimum
}

func percent(score float64) int {
	return int(score*100 + 0.5)
}

func maxFloat(a float64, b float64) float64 {
	if a > b {
		return a
	}
	return b
}

func (i *Index) Len() int {
	if i == nil {
		return 0
	}
	return len(i.entries)
}
