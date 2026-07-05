package scan

import (
	"os"
	"path/filepath"
	"testing"
)

func TestDiscoverFilesFiltersExtensionsAndExcludes(t *testing.T) {
	root := t.TempDir()
	writeFile(t, root, "src/a.ts", "")
	writeFile(t, root, "src/b.go", "")
	writeFile(t, root, "node_modules/c.ts", "")
	writeFile(t, root, "custom/d.tsx", "")

	files, err := DiscoverFiles(root, Options{
		Extensions: []string{"ts"},
		Exclude:    []string{"custom"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(files) != 1 || filepath.Base(files[0]) != "a.ts" {
		t.Fatalf("DiscoverFiles() = %#v, want only a.ts", files)
	}
}

func TestDiscoverFilesSkipsSymlinkedFiles(t *testing.T) {
	root := t.TempDir()
	writeFile(t, root, "src/a.ts", "")
	outside := filepath.Join(t.TempDir(), "outside.ts")
	if err := os.WriteFile(outside, []byte(""), 0o644); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(root, "src/leak.ts")
	if err := os.Symlink(outside, link); err != nil {
		t.Skipf("symlinks are not supported: %v", err)
	}

	files, err := DiscoverFiles(root, Options{})
	if err != nil {
		t.Fatal(err)
	}
	if len(files) != 1 || filepath.Base(files[0]) != "a.ts" {
		t.Fatalf("DiscoverFiles() = %#v, want only a.ts", files)
	}
}

func writeFile(t *testing.T, root string, name string, content string) {
	t.Helper()
	path := filepath.Join(root, name)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}
