package tmux

import (
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func TestNoProductionDefaultSelector(t *testing.T) {
	t.Parallel()
	probeCalls := 0
	err := filepath.WalkDir("../..", func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() || !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		source := string(data)
		for _, forbidden := range []string{"LegacyServer", `name: defaultServerLabel`, `"-L", "default"`} {
			if strings.Contains(source, forbidden) {
				t.Errorf("%s retains %q", path, forbidden)
			}
		}
		file, err := parser.ParseFile(token.NewFileSet(), path, data, 0)
		if err != nil {
			return err
		}
		for _, decl := range file.Decls {
			fn, ok := decl.(*ast.FuncDecl)
			if !ok {
				continue
			}
			ast.Inspect(fn, func(node ast.Node) bool {
				call, ok := node.(*ast.CallExpr)
				if ok {
					if name, ok := call.Fun.(*ast.Ident); ok && name.Name == "defaultSocketPath" {
						probeCalls++
						if fn.Name.Name != "ProbeDefaultSessions" {
							t.Errorf("%s: %s accesses the default socket", path, fn.Name.Name)
						}
					}
				}
				// A default socket literal is permitted only in the named path builder;
				// the label validator also names default to reject it.
				literal, ok := node.(*ast.BasicLit)
				if !ok || literal.Kind != token.STRING {
					return true
				}
				value, _ := strconv.Unquote(literal.Value)
				if file.Name.Name == "tmux" && (value == "default" || strings.HasSuffix(value, "/default")) && fn.Name.Name != "defaultSocketPath" && fn.Name.Name != "ValidateNamedLabel" {
					t.Errorf("%s: %s builds a default selector", path, fn.Name.Name)
				}
				return true
			})
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if probeCalls != 1 {
		t.Fatalf("default socket probe paths=%d, want exactly one", probeCalls)
	}
}
