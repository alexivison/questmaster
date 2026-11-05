package tmuxtest

import (
	"go/parser"
	"go/token"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

const harnessImportPath = "github.com/alexivison/questmaster/internal/tmux/tmuxtest"

// TestHarnessIsNotImportedByProductionCode fails if any non-test Go file in the
// module imports the harness. Test files may import it; production files may not.
func TestHarnessIsNotImportedByProductionCode(t *testing.T) {
	t.Parallel()
	root := moduleRoot(t)
	fset := token.NewFileSet()
	scanned := 0

	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			if path != root && strings.HasPrefix(d.Name(), ".") {
				return filepath.SkipDir
			}
			return nil
		}
		if filepath.Ext(path) != ".go" || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		scanned++
		file, err := parser.ParseFile(fset, path, nil, parser.ImportsOnly)
		if err != nil {
			return err
		}
		for _, imp := range file.Imports {
			if mustUnquote(t, imp.Path.Value) == harnessImportPath {
				rel, _ := filepath.Rel(root, path)
				t.Errorf("%s imports the tmux test harness; only _test.go files may", rel)
			}
		}
		return nil
	})
	if err != nil {
		t.Fatalf("scan module: %v", err)
	}
	if scanned == 0 {
		t.Fatal("scanned no production files; the module root is wrong")
	}
}

// moduleRoot walks up from the package directory to the directory holding go.mod.
func moduleRoot(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Fatal("go.mod not found above the test package")
		}
		dir = parent
	}
}

func mustUnquote(t *testing.T, quoted string) string {
	t.Helper()
	s, err := strconv.Unquote(quoted)
	if err != nil {
		t.Fatalf("import path %s: %v", quoted, err)
	}
	return s
}
