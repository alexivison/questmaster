package tmux

import (
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// TestNoTmuxCallInsideAManifestUpdate fails when a Store.Update closure calls
// a tmux client method. The closure runs under the session's manifest flock,
// so a slow or stuck tmux server would hold every other manifest writer; tmux
// calls belong after the commit (state.WriteCommittedPaneTitle for titles).
// It reads source, so a tmux call behind a helper the closure calls is not
// seen.
func TestNoTmuxCallInsideAManifestUpdate(t *testing.T) {
	t.Parallel()
	tmuxCalls := map[string]bool{"Run": true}
	client := reflect.TypeOf(&Client{})
	for i := range client.NumMethod() {
		tmuxCalls[client.Method(i).Name] = true
	}

	root := findModuleRoot(t)
	fset := token.NewFileSet()
	closures := 0
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			if path != root && (strings.HasPrefix(d.Name(), ".") || d.Name() == "app") {
				return filepath.SkipDir
			}
			return nil
		}
		if filepath.Ext(path) != ".go" || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		file, err := parser.ParseFile(fset, path, nil, 0)
		if err != nil {
			return err
		}
		ast.Inspect(file, func(n ast.Node) bool {
			update, ok := manifestUpdateClosure(n)
			if !ok {
				return true
			}
			closures++
			ast.Inspect(update.Body, func(n ast.Node) bool {
				call, ok := n.(*ast.CallExpr)
				if !ok {
					return true
				}
				if sel, ok := call.Fun.(*ast.SelectorExpr); ok && tmuxCalls[sel.Sel.Name] {
					rel, _ := filepath.Rel(root, path)
					t.Errorf("%s:%d calls %s inside a manifest Update closure", rel, fset.Position(call.Pos()).Line, sel.Sel.Name)
				}
				return true
			})
			return true
		})
		return nil
	})
	if err != nil {
		t.Fatalf("scan module: %v", err)
	}
	if closures == 0 {
		t.Fatal("found no manifest Update closures; the scan is broken")
	}
}

// manifestUpdateClosure matches x.Update(id, func(m *state.Manifest) {...}).
func manifestUpdateClosure(n ast.Node) (*ast.FuncLit, bool) {
	call, ok := n.(*ast.CallExpr)
	if !ok || len(call.Args) != 2 {
		return nil, false
	}
	if sel, ok := call.Fun.(*ast.SelectorExpr); !ok || sel.Sel.Name != "Update" {
		return nil, false
	}
	fn, ok := call.Args[1].(*ast.FuncLit)
	if !ok || len(fn.Type.Params.List) != 1 {
		return nil, false
	}
	star, ok := fn.Type.Params.List[0].Type.(*ast.StarExpr)
	if !ok {
		return nil, false
	}
	switch typ := star.X.(type) {
	case *ast.Ident:
		return fn, typ.Name == "Manifest"
	case *ast.SelectorExpr:
		pkg, ok := typ.X.(*ast.Ident)
		return fn, ok && pkg.Name == "state" && typ.Sel.Name == "Manifest"
	}
	return nil, false
}

func findModuleRoot(t *testing.T) string {
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
