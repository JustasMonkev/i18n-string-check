package index

import (
	"encoding/json"
	"fmt"
	"os"
	"regexp"
	"sort"
	"strings"
	"sync"
	"unicode"

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
	entries  map[string][]Match
	patterns []patternMatch
	all      []Match
	sim      simIndex
}

// simIndex holds the similarity-matching data: tokens interned to dense ids,
// an inverted index from token id to eligible entries, and pooled per-query
// scratch buffers. Word overlap is computed by counting posting hits per
// candidate instead of intersecting per-entry word-set maps, so a lookup
// never iterates or hashes candidate word sets.
type simIndex struct {
	// entriesMeta is aligned with Index.all; tokenCount is zero for entries
	// that are not similarity candidates.
	entriesMeta []simEntryMeta
	vocab       map[string]int32
	// postings maps a token id to the similarity-eligible entries containing
	// that token. Candidate discovery only walks tokens of length >= 3;
	// shorter tokens are indexed so overlap counts stay exact.
	postings [][]int32
	scratch  sync.Pool
}

type simEntryMeta struct {
	runeCount  int32
	tokenCount int32
}

// simScratch is the reusable per-query state. counts is indexed by entry:
// 0 untouched, -1 rejected by the length filter, otherwise the number of
// shared tokens so far. touched lists the entries to reset after the query.
type simScratch struct {
	counts    []int32
	touched   []int32
	longIDs   []int32
	shortIDs  []int32
	tokenSeen []uint32
	epoch     uint32
	unknown   []string
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

	idx := &Index{entries: map[string][]Match{}, sim: simIndex{vocab: map[string]int32{}}}
	for key, value := range raw {
		if normalize.TrimmedLength(value) < minLength {
			continue
		}
		idx.add(key, value)
	}
	idx.finalizeSimilarity()

	return idx, nil
}

// finalizeSimilarity sizes the pooled query scratch to the finished index.
// It must run after the last add.
func (i *Index) finalizeSimilarity() {
	entryCount := len(i.all)
	vocabSize := len(i.sim.vocab)
	i.sim.scratch.New = func() any {
		return &simScratch{
			counts:    make([]int32, entryCount),
			tokenSeen: make([]uint32, vocabSize),
		}
	}
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
	index := int32(len(i.all))
	match := Match{
		Key:             key,
		Value:           value,
		NormalizedValue: normalized,
	}
	i.entries[normalized] = append(i.entries[normalized], match)
	i.all = append(i.all, match)
	var meta simEntryMeta
	if runeCount, ok := similarityEligible(normalized); ok {
		words := wordSet(normalized)
		meta = simEntryMeta{runeCount: int32(runeCount), tokenCount: int32(len(words))}
		for word := range words {
			id, ok := i.sim.vocab[word]
			if !ok {
				id = int32(len(i.sim.postings))
				i.sim.vocab[word] = id
				i.sim.postings = append(i.sim.postings, nil)
			}
			i.sim.postings[id] = append(i.sim.postings[id], index)
		}
	}
	i.sim.entriesMeta = append(i.sim.entriesMeta, meta)
	for _, template := range translationPatternTemplates(value) {
		pattern, prefix, ok := compileTranslationPattern(template)
		if ok {
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
	queryRunes, ok := similarityEligible(normalized)
	if !ok {
		return nil
	}
	scratch := i.sim.scratch.Get().(*simScratch)
	scratch.collectQueryTokens(normalized, i.sim.vocab)
	// Without a shared token of length >= 3 there can be no candidates, so
	// most non-translation strings stop here before any counting work.
	if len(scratch.longIDs) == 0 {
		i.sim.scratch.Put(scratch)
		return nil
	}
	queryTokens := len(scratch.longIDs) + len(scratch.shortIDs) + countUnique(scratch.unknown)

	// Discovery walks the postings of tokens with length >= 3, counting
	// shared tokens per entry; the length-ratio filter runs once per entry
	// on first touch. Short-token postings then top up the counts of already
	// discovered candidates so overlap ratios match full word-set
	// intersection.
	for _, id := range scratch.longIDs {
		for _, entry := range i.sim.postings[id] {
			switch count := scratch.counts[entry]; {
			case count > 0:
				scratch.counts[entry] = count + 1
			case count == 0:
				if likelySimilarLength(queryRunes, int(i.sim.entriesMeta[entry].runeCount)) {
					scratch.counts[entry] = 1
				} else {
					scratch.counts[entry] = -1
				}
				scratch.touched = append(scratch.touched, entry)
			}
		}
	}
	for _, id := range scratch.shortIDs {
		for _, entry := range i.sim.postings[id] {
			if scratch.counts[entry] > 0 {
				scratch.counts[entry]++
			}
		}
	}

	var matches []Match
	for _, entry := range scratch.touched {
		shared := scratch.counts[entry]
		scratch.counts[entry] = 0
		if shared <= 0 {
			continue
		}
		match := i.all[entry]
		if normalized == match.NormalizedValue {
			continue
		}
		meta := i.sim.entriesMeta[entry]
		denominator := queryTokens
		if int(meta.tokenCount) > denominator {
			denominator = int(meta.tokenCount)
		}
		overlap := float64(shared) / float64(denominator)
		details, ok := similarityDetails(normalized, queryRunes, match.NormalizedValue, int(meta.runeCount), overlap)
		if ok {
			match.Reason = details.Reason
			match.Score = details.Score
			match.Why = details.Why
			matches = append(matches, match)
		}
	}
	scratch.touched = scratch.touched[:0]
	i.sim.scratch.Put(scratch)

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

// collectQueryTokens splits the query into the tokens wordSet would produce.
// Tokens known to the index vocabulary are deduplicated into longIDs/shortIDs
// (split at the 3-byte candidate-discovery cutoff); unknown tokens are stashed
// in unknown, still with duplicates, for the overlap denominator count.
func (s *simScratch) collectQueryTokens(normalized string, vocab map[string]int32) {
	s.epoch++
	s.longIDs = s.longIDs[:0]
	s.shortIDs = s.shortIDs[:0]
	s.unknown = s.unknown[:0]
	appendToken := func(token string) {
		if id, ok := vocab[token]; ok {
			if s.tokenSeen[id] == s.epoch {
				return
			}
			s.tokenSeen[id] = s.epoch
			if len(token) >= 3 {
				s.longIDs = append(s.longIDs, id)
			} else {
				s.shortIDs = append(s.shortIDs, id)
			}
			return
		}
		s.unknown = append(s.unknown, token)
	}
	start := -1
	for i, r := range normalized {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			if start < 0 {
				start = i
			}
			continue
		}
		if start >= 0 {
			appendToken(normalized[start:i])
			start = -1
		}
	}
	if start >= 0 {
		appendToken(normalized[start:])
	}
}

// countUnique counts distinct strings with a quadratic scan; queries carry at
// most a handful of unknown tokens, so this beats hashing them into a map.
func countUnique(tokens []string) int {
	unique := 0
	for i, token := range tokens {
		duplicate := false
		for _, previous := range tokens[:i] {
			if previous == token {
				duplicate = true
				break
			}
		}
		if !duplicate {
			unique++
		}
	}
	return unique
}

func likelySimilarLength(aLen int, bLen int) bool {
	if aLen == 0 || bLen == 0 {
		return false
	}
	shorter, longer := aLen, bLen
	if shorter > longer {
		shorter, longer = longer, shorter
	}
	// Integer form of shorter/longer >= 0.5, avoiding the division.
	return 2*shorter >= longer
}

func translationPatternTemplates(value string) []string {
	plurals := icuPluralTemplates(value)
	if len(plurals) > 0 {
		return plurals
	}
	return []string{value}
}

// compileTranslationPattern also returns the pattern's literal prefix (the
// normalized text before the first placeholder), which the lookup uses to
// skip the regex engine. It is computed here because
// regexp.(*Regexp).LiteralPrefix returns an empty prefix for anchored
// patterns, which would disable that guard.
func compileTranslationPattern(template string) (*regexp.Regexp, string, bool) {
	normalized := normalize.Normalize(template)
	var out strings.Builder
	var prefix strings.Builder
	prefixDone := false
	out.WriteString("^")
	placeholderCount := 0
	literalCount := 0
	for i := 0; i < len(normalized); i++ {
		switch normalized[i] {
		case '{':
			end := strings.IndexByte(normalized[i+1:], '}')
			if end < 0 {
				out.WriteString(regexp.QuoteMeta(normalized[i : i+1]))
				if !prefixDone {
					prefix.WriteByte(normalized[i])
				}
				literalCount++
				continue
			}
			content := normalized[i+1 : i+1+end]
			if content == "" || strings.Contains(content, ",") || strings.ContainsAny(content, "{}") {
				return nil, "", false
			}
			out.WriteString(".+")
			prefixDone = true
			placeholderCount++
			i += end + 1
		case '#':
			out.WriteString(`\d+`)
			prefixDone = true
			placeholderCount++
		default:
			out.WriteString(regexp.QuoteMeta(normalized[i : i+1]))
			if !prefixDone {
				prefix.WriteByte(normalized[i])
			}
			if isPatternLiteral(normalized[i]) {
				literalCount++
			}
		}
	}
	out.WriteString("$")
	if placeholderCount == 0 || literalCount < 3 {
		return nil, "", false
	}
	pattern, err := regexp.Compile(out.String())
	if err != nil {
		return nil, "", false
	}
	return pattern, prefix.String(), true
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

// similarityEligible reports whether a value is long enough for similarity
// matching (>= 24 runes and >= 5 whitespace fields) and returns its rune
// count.
func similarityEligible(value string) (int, bool) {
	runeCount, fieldCount := similarityStats(value)
	if runeCount < 24 || fieldCount < 5 {
		return 0, false
	}
	return runeCount, true
}

// similarityStats counts runes and whitespace-separated fields in one pass,
// matching utf8.RuneCountInString plus len(strings.Fields(value)). ASCII
// input, the overwhelmingly common case, is handled byte-wise without rune
// decoding.
func similarityStats(value string) (int, int) {
	runeCount := 0
	count := 0
	inField := false
	for i := 0; i < len(value); i++ {
		b := value[i]
		if b >= 0x80 {
			return similarityStatsRunes(value)
		}
		runeCount++
		if b == ' ' || ('\t' <= b && b <= '\r') {
			inField = false
			continue
		}
		if !inField {
			inField = true
			count++
		}
	}
	return runeCount, count
}

func similarityStatsRunes(value string) (int, int) {
	runeCount := 0
	count := 0
	inField := false
	for _, r := range value {
		runeCount++
		if unicode.IsSpace(r) {
			inField = false
			continue
		}
		if !inField {
			inField = true
			count++
		}
	}
	return runeCount, count
}

type similarityDetailsResult struct {
	Reason string
	Score  float64
	Why    string
}

// similarityDetails reports how similar query a is to candidate b. Both sides
// are already known to be similarity candidates, rune counts are precomputed,
// and the word overlap ratio was already derived from posting counts. The
// expensive Levenshtein distance only runs when the cheap word-overlap and
// length-ratio bounds show its threshold is still reachable: the edit
// similarity can never exceed shorterLen/longerLen.
func similarityDetails(a string, aRunes int, b string, bRunes int, wordOverlap float64) (similarityDetailsResult, bool) {
	shorter, longer := a, b
	shorterLen, longerLen := aRunes, bRunes
	bIsLonger := true
	if aRunes > bRunes {
		shorter, longer = b, a
		shorterLen, longerLen = bRunes, aRunes
		bIsLonger = false
	}
	lengthRatio := float64(shorterLen) / float64(longerLen)
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

func wordSet(value string) map[string]bool {
	out := map[string]bool{}
	start := -1
	for i, r := range value {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			if start < 0 {
				start = i
			}
			continue
		}
		if start >= 0 {
			out[value[start:i]] = true
			start = -1
		}
	}
	if start >= 0 {
		out[value[start:]] = true
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
