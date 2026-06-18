package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	i18nindex "github.com/justasmonkev/i18n-string-check/internal/index"
	"github.com/justasmonkev/i18n-string-check/internal/scan"
)

// benchCorpus generates a deterministic synthetic project: an en.json with
// translation values plus source files containing a realistic mix of JSX
// text, attributes, template strings, and plain literals. Some literals match
// translations exactly, some only via similarity, and most do not match.
type benchCorpus struct {
	root   string
	enJSON string
	files  []string
	index  *i18nindex.Index
}

var benchPhrases = []string{
	"Sign in to your account",
	"Your password has been updated successfully",
	"We sent a verification link to your email address",
	"You have been invited to join the workspace",
	"Your weekly report is ready to download",
	"Enable biometric authentication for faster access",
	"The session has expired, please sign in again",
	"Changes were saved automatically to your draft",
	"This action cannot be undone once confirmed",
	"Select a plan that matches your team size",
}

func buildBenchCorpus(tb testing.TB, fileCount int) *benchCorpus {
	return buildBenchCorpusWithScale(tb, fileCount, 1)
}

func buildBenchCorpusWithScale(tb testing.TB, fileCount int, scale int) *benchCorpus {
	tb.Helper()
	root := tb.TempDir()
	if scale < 1 {
		scale = 1
	}

	translations := map[string]any{}
	for i, phrase := range benchPhrases {
		translations[fmt.Sprintf("section%d", i)] = map[string]any{
			"title":   phrase,
			"body":    phrase + " and continue where you left off",
			"tooltip": fmt.Sprintf("Open item number {count} of %d in the list", i+10),
		}
	}
	for i := 0; i < 400; i++ {
		translations[fmt.Sprintf("misc.key%d", i)] = fmt.Sprintf("Translation value number %d for the benchmark corpus", i)
	}
	enBytes, err := json.Marshal(translations)
	if err != nil {
		tb.Fatal(err)
	}
	enJSON := filepath.Join(root, "en.json")
	if err := os.WriteFile(enJSON, enBytes, 0o644); err != nil {
		tb.Fatal(err)
	}

	srcDir := filepath.Join(root, "src")
	if err := os.MkdirAll(filepath.Join(srcDir, "components"), 0o755); err != nil {
		tb.Fatal(err)
	}
	var files []string
	for i := 0; i < fileCount; i++ {
		var path string
		var content string
		switch i % 3 {
		case 0:
			path = filepath.Join(srcDir, "components", fmt.Sprintf("Component%d.tsx", i))
			content = benchTSX(i, 30*scale)
		case 1:
			path = filepath.Join(srcDir, fmt.Sprintf("module%d.ts", i))
			content = benchTS(i, 40*scale)
		default:
			path = filepath.Join(srcDir, fmt.Sprintf("legacy%d.js", i))
			content = benchJS(i, 50*scale)
		}
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			tb.Fatal(err)
		}
		files = append(files, path)
	}

	idx, err := i18nindex.Load(enJSON, 8)
	if err != nil {
		tb.Fatal(err)
	}
	return &benchCorpus{root: root, enJSON: enJSON, files: files, index: idx}
}

func benchTSX(seed int, sectionCount int) string {
	phrase := benchPhrases[seed%len(benchPhrases)]
	var b strings.Builder
	b.WriteString("import React from 'react';\nimport { t } from '../i18n';\n\n")
	fmt.Fprintf(&b, "export function Component%d() {\n  return (\n    <div className=\"page-wrapper\">\n", seed)
	for j := 0; j < sectionCount; j++ {
		fmt.Fprintf(&b, "      <section data-testid=\"section-%d\">\n", j)
		fmt.Fprintf(&b, "        <h2 title=\"Heading number %d for layout\">{t('section%d.title')}</h2>\n", j, j%10)
		if j%5 == 0 {
			fmt.Fprintf(&b, "        <p>%s</p>\n", phrase)
		} else {
			fmt.Fprintf(&b, "        <p>Static layout copy block %d-%d that should not match anything</p>\n", seed, j)
		}
		fmt.Fprintf(&b, "        <input placeholder=\"Enter the value for field %d here\" aria-label=\"field-%d\" />\n", j, j)
		fmt.Fprintf(&b, "        <button onClick={() => track(`click-%d-${'%d'}`)}>{t('misc.key%d')}</button>\n", j, j, j)
		b.WriteString("      </section>\n")
	}
	b.WriteString("    </div>\n  );\n}\n")
	return b.String()
}

func benchTS(seed int, entryCount int) string {
	var b strings.Builder
	b.WriteString("import { logger } from './logger';\n\n")
	fmt.Fprintf(&b, "export const config%d = {\n", seed)
	for j := 0; j < entryCount; j++ {
		fmt.Fprintf(&b, "  key%d: 'configuration value %d for module %d',\n", j, j, seed)
	}
	b.WriteString("};\n\n")
	for j := 0; j < entryCount; j++ {
		fmt.Fprintf(&b, "export function helper%d(input: string): string {\n", j)
		fmt.Fprintf(&b, "  logger.debug('processing helper %d with input', input);\n", j)
		if j%7 == 0 {
			fmt.Fprintf(&b, "  return 'Translation value number %d for the benchmark corpus';\n", j)
		} else {
			fmt.Fprintf(&b, "  return `template result %d ` + input;\n", j)
		}
		b.WriteString("}\n\n")
	}
	return b.String()
}

func benchJS(seed int, functionCount int) string {
	var b strings.Builder
	b.WriteString("const path = require('path');\n\n")
	for j := 0; j < functionCount; j++ {
		fmt.Fprintf(&b, "function legacy%d() {\n", j)
		fmt.Fprintf(&b, "  const message = 'legacy message %d in file %d with some words';\n", j, seed)
		fmt.Fprintf(&b, "  const tpl = `static template %d without substitutions`;\n", j)
		b.WriteString("  return message + tpl;\n}\n\n")
	}
	return b.String()
}

// BenchmarkPipeline measures the end-to-end scan-and-check path: file
// discovery, tree-sitter extraction, and index matching, mirroring run().
func BenchmarkPipeline(b *testing.B) {
	corpus := buildBenchCorpus(b, 120)
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		files, err := scan.DiscoverFiles(filepath.Join(corpus.root, "src"), scan.Options{})
		if err != nil {
			b.Fatal(err)
		}
		findings, err := scanAndMatch(files, 8, corpus.index, modeSource, false)
		if err != nil {
			b.Fatal(err)
		}
		if len(findings) == 0 {
			b.Fatal("expected findings")
		}
	}
}

// BenchmarkPipelineSimilarity is the same pipeline with --similarity-flow,
// which exercises the similarity matching path for every unmatched literal.
func BenchmarkPipelineSimilarity(b *testing.B) {
	corpus := buildBenchCorpus(b, 120)
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		files, err := scan.DiscoverFiles(filepath.Join(corpus.root, "src"), scan.Options{})
		if err != nil {
			b.Fatal(err)
		}
		if _, err := scanAndMatch(files, 8, corpus.index, modeSource, true); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkPipelineLargeFilesSimilarity keeps the file count stable but makes
// each generated source file 10x larger, stressing per-file parsing and the
// per-literal similarity path.
func BenchmarkPipelineLargeFilesSimilarity(b *testing.B) {
	corpus := buildBenchCorpusWithScale(b, 120, 10)
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		files, err := scan.DiscoverFiles(filepath.Join(corpus.root, "src"), scan.Options{})
		if err != nil {
			b.Fatal(err)
		}
		if _, err := scanAndMatch(files, 8, corpus.index, modeSource, true); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkPipelineLargeFiles keeps the file count stable but makes each
// generated source file 10x larger, stressing per-file parsing without
// enabling the extra similarity matching pass.
func BenchmarkPipelineLargeFiles(b *testing.B) {
	corpus := buildBenchCorpusWithScale(b, 120, 10)
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		files, err := scan.DiscoverFiles(filepath.Join(corpus.root, "src"), scan.Options{})
		if err != nil {
			b.Fatal(err)
		}
		findings, err := scanAndMatch(files, 8, corpus.index, modeSource, false)
		if err != nil {
			b.Fatal(err)
		}
		if len(findings) == 0 {
			b.Fatal("expected findings")
		}
	}
}

// BenchmarkScanOneLarge measures extraction and matching for one large TSX
// file, isolating the per-file hot path from worker-pool scheduling.
func BenchmarkScanOneLarge(b *testing.B) {
	corpus := buildBenchCorpusWithScale(b, 3, 10)
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		result := scanOne(corpus.files[0], 8, corpus.index, modeSource, true)
		if result.err != nil {
			b.Fatal(result.err)
		}
	}
}

// BenchmarkScanOne measures a single file scan (extraction + matching) on the
// largest generated file type, isolating per-file cost from the worker pool.
func BenchmarkScanOne(b *testing.B) {
	corpus := buildBenchCorpus(b, 3)
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		result := scanOne(corpus.files[0], 8, corpus.index, modeSource, false)
		if result.err != nil {
			b.Fatal(result.err)
		}
	}
}
