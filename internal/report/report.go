package report

import (
	"encoding/json"
	"fmt"
	"io"
	"sort"

	"github.com/justasmonkev/i18n-string-check/internal/index"
)

type Finding struct {
	File              string        `json:"file"`
	Line              int           `json:"line"`
	Column            int           `json:"column"`
	Type              string        `json:"type"`
	Literal           string        `json:"literal"`
	NormalizedLiteral string        `json:"normalizedLiteral"`
	Matches           []index.Match `json:"matches"`
}

type Summary struct {
	Found    bool      `json:"found"`
	Count    int       `json:"count"`
	Files    int       `json:"files"`
	Findings []Finding `json:"findings"`
}

func NewSummary(findings []Finding) Summary {
	SortFindings(findings)
	files := map[string]bool{}
	for _, finding := range findings {
		files[finding.File] = true
	}
	return Summary{
		Found:    len(findings) > 0,
		Count:    len(findings),
		Files:    len(files),
		Findings: findings,
	}
}

func SortFindings(findings []Finding) {
	sort.Slice(findings, func(i, j int) bool {
		if findings[i].File != findings[j].File {
			return findings[i].File < findings[j].File
		}
		if findings[i].Line != findings[j].Line {
			return findings[i].Line < findings[j].Line
		}
		return findings[i].Column < findings[j].Column
	})
}

func WriteText(w io.Writer, summary Summary) error {
	for _, finding := range summary.Findings {
		if finding.Type == "changed-translation-value" {
			if err := writeLikelyStaleText(w, finding); err != nil {
				return err
			}
			continue
		}
		if _, err := fmt.Fprintf(w, "%s: %s:%d\n", findingTitle(finding), finding.File, finding.Line); err != nil {
			return err
		}
		if _, err := fmt.Fprintf(w, "  literal: %q\n", finding.Literal); err != nil {
			return err
		}
		if len(finding.Matches) == 1 {
			match := finding.Matches[0]
			if _, err := fmt.Fprintf(w, "  matches en.json key: %q value: %q\n", match.Key, match.Value); err != nil {
				return err
			}
			if _, err := fmt.Fprintln(w, "  fix: "+fixText(finding, match.Key)); err != nil {
				return err
			}
		} else {
			if _, err := fmt.Fprintln(w, "  matches multiple en.json keys:"); err != nil {
				return err
			}
			for _, match := range finding.Matches {
				if _, err := fmt.Fprintf(w, "    - %q value: %q\n", match.Key, match.Value); err != nil {
					return err
				}
			}
			if _, err := fmt.Fprintln(w, "  fix: "+multiFixText(finding)); err != nil {
				return err
			}
		}
		if _, err := fmt.Fprintln(w); err != nil {
			return err
		}
	}
	if summary.Count > 0 {
		_, err := fmt.Fprintf(w, "→ %d i18n issues found in %d files.\n", summary.Count, summary.Files)
		return err
	}
	_, err := fmt.Fprintln(w, "no i18n issues found.")
	return err
}

func writeLikelyStaleText(w io.Writer, finding Finding) error {
	if _, err := fmt.Fprintf(w, "%s: %s:%d\n", findingTitle(finding), finding.File, finding.Line); err != nil {
		return err
	}
	if _, err := fmt.Fprintln(w, "  current code string:"); err != nil {
		return err
	}
	if _, err := fmt.Fprintf(w, "    %q\n\n", finding.Literal); err != nil {
		return err
	}

	if len(finding.Matches) == 1 {
		match := finding.Matches[0]
		if _, err := fmt.Fprintln(w, "  similar en.json value:"); err != nil {
			return err
		}
		if _, err := fmt.Fprintf(w, "    key: %q\n", match.Key); err != nil {
			return err
		}
		if _, err := fmt.Fprintf(w, "    value: %q\n\n", match.Value); err != nil {
			return err
		}
		if _, err := fmt.Fprintf(w, "  similarity: %d%%\n", percent(match.Score)); err != nil {
			return err
		}
		if _, err := fmt.Fprintf(w, "  why: %s\n", fallback(match.Why, "similar to the current en.json value")); err != nil {
			return err
		}
		if _, err := fmt.Fprintln(w, "  fix: "+fixText(finding, match.Key)); err != nil {
			return err
		}
		_, err := fmt.Fprintln(w)
		return err
	}

	if _, err := fmt.Fprintln(w, "  similar en.json values:"); err != nil {
		return err
	}
	for i, match := range finding.Matches {
		if _, err := fmt.Fprintf(w, "    %d. key: %q value: %q similarity: %d%%\n", i+1, match.Key, match.Value, percent(match.Score)); err != nil {
			return err
		}
		if match.Why != "" {
			if _, err := fmt.Fprintf(w, "       why: %s\n", match.Why); err != nil {
				return err
			}
		}
	}
	if _, err := fmt.Fprintln(w, "  fix: "+multiFixText(finding)); err != nil {
		return err
	}
	_, err := fmt.Fprintln(w)
	return err
}

func findingTitle(finding Finding) string {
	switch finding.Type {
	case "changed-translation-value":
		return "likely stale hardcoded translation"
	case "test-value-mismatch":
		return "translation value mismatch"
	default:
		return "hardcoded translation"
	}
}

func fixText(finding Finding, key string) string {
	switch finding.Type {
	case "changed-translation-value":
		return "replace with t(\"" + key + "\"), or mark this literal intentional"
	case "test-value-mismatch":
		return "update the test literal to the current en.json value for " + fmt.Sprintf("%q", key)
	default:
		return "replace with t(\"" + key + "\") or your project's i18n helper"
	}
}

func multiFixText(finding Finding) string {
	switch finding.Type {
	case "changed-translation-value":
		return "choose the correct t(\"...\") key, or mark this literal intentional"
	case "test-value-mismatch":
		return "update the test literal to the correct current en.json value for this context"
	default:
		return "replace with the correct t(\"...\") key for this context"
	}
}

func fallback(value string, replacement string) string {
	if value == "" {
		return replacement
	}
	return value
}

func percent(score float64) int {
	return int(score*100 + 0.5)
}

func WriteJSON(w io.Writer, summary Summary) error {
	encoder := json.NewEncoder(w)
	encoder.SetIndent("", "  ")
	return encoder.Encode(summary)
}
