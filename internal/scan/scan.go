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
	excludes := append([]string{}, DefaultExcluded...)
	excludes = append(excludes, opts.Exclude...)

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

func matchesExclude(rel string, base string, excludes []string) bool {
	slashRel := filepath.ToSlash(rel)
	for _, pattern := range excludes {
		pattern = strings.TrimSpace(pattern)
		if pattern == "" {
			continue
		}
		slashPattern := filepath.ToSlash(pattern)
		if !strings.ContainsAny(slashPattern, "*?[") {
			if base == slashPattern || slashRel == slashPattern || hasPathSegment(slashRel, slashPattern) {
				return true
			}
			continue
		}
		if ok, _ := filepath.Match(slashPattern, slashRel); ok {
			return true
		}
		if ok, _ := filepath.Match(slashPattern, base); ok {
			return true
		}
	}
	return false
}

func hasPathSegment(path string, segment string) bool {
	for _, part := range strings.Split(path, "/") {
		if part == segment {
			return true
		}
	}
	return false
}
