package scan

import (
	"io/fs"
	"path/filepath"
	"sort"
	"strings"
)

var DefaultExcluded = []string{
	"node_modules",
	".git",
	"dist",
	"build",
	"coverage",
	".next",
	"playwright-report",
	"test-results",
}

type Options struct {
	Extensions []string
	Exclude    []string
}

func DiscoverFiles(root string, opts Options) ([]string, error) {
	extensions := normalizeExtensions(opts.Extensions)
	patterns := append([]string{}, DefaultExcluded...)
	patterns = append(patterns, opts.Exclude...)
	excludes := compileExcludes(patterns)

	var files []string
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, relErr := filepath.Rel(root, path)
		if relErr != nil {
			return relErr
		}
		if rel == "." {
			return nil
		}

		if matchesExclude(rel, d.Name(), excludes) {
			if d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		if d.IsDir() {
			return nil
		}

		if extensions[strings.TrimPrefix(filepath.Ext(path), ".")] {
			files = append(files, path)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	sort.Strings(files)
	return files, nil
}

func normalizeExtensions(exts []string) map[string]bool {
	if len(exts) == 0 {
		exts = []string{"ts", "tsx", "js", "jsx"}
	}
	out := map[string]bool{}
	for _, ext := range exts {
		cleaned := strings.TrimSpace(strings.TrimPrefix(ext, "."))
		if cleaned != "" {
			out[cleaned] = true
		}
	}
	return out
}

type excludePattern struct {
	pattern string
	isGlob  bool
}

// compileExcludes cleans the patterns once so the per-entry match loop does
// not re-trim and re-classify each pattern for every walked path.
func compileExcludes(patterns []string) []excludePattern {
	out := make([]excludePattern, 0, len(patterns))
	for _, pattern := range patterns {
		pattern = strings.TrimSpace(pattern)
		if pattern == "" {
			continue
		}
		slashPattern := filepath.ToSlash(pattern)
		out = append(out, excludePattern{
			pattern: slashPattern,
			isGlob:  strings.ContainsAny(slashPattern, "*?["),
		})
	}
	return out
}

func matchesExclude(rel string, base string, excludes []excludePattern) bool {
	slashRel := filepath.ToSlash(rel)
	for _, exclude := range excludes {
		if !exclude.isGlob {
			if base == exclude.pattern || slashRel == exclude.pattern || hasPathSegment(slashRel, exclude.pattern) {
				return true
			}
			continue
		}
		if ok, _ := filepath.Match(exclude.pattern, slashRel); ok {
			return true
		}
		if ok, _ := filepath.Match(exclude.pattern, base); ok {
			return true
		}
	}
	return false
}

func hasPathSegment(path string, segment string) bool {
	for start := 0; start <= len(path); {
		end := strings.IndexByte(path[start:], '/')
		if end < 0 {
			return path[start:] == segment
		}
		if path[start:start+end] == segment {
			return true
		}
		start += end + 1
	}
	return false
}
