package tmux

import (
	"fmt"
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
		findings, calls, err := defaultSelectorFindings(path, data)
		if err != nil {
			return err
		}
		probeCalls += calls
		for _, finding := range findings {
			t.Errorf("%s: %s", path, finding)
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

func defaultSelectorFindings(path string, data []byte) ([]string, int, error) {
	file, err := parser.ParseFile(token.NewFileSet(), path, data, 0)
	if err != nil {
		return nil, 0, err
	}
	var findings []string
	calls := 0
	constants := map[string]ast.Expr{}
	for _, decl := range file.Decls {
		if group, ok := decl.(*ast.GenDecl); ok {
			for _, spec := range group.Specs {
				if value, ok := spec.(*ast.ValueSpec); ok && len(value.Names) == len(value.Values) {
					for i, name := range value.Names {
						constants[name.Name] = value.Values[i]
					}
				}
			}
		}
	}
	var value func(ast.Expr, int) string
	value = func(expr ast.Expr, depth int) string {
		if depth > len(constants)+1 {
			return ""
		}
		switch e := expr.(type) {
		case *ast.BasicLit:
			if e.Kind == token.STRING {
				v, _ := strconv.Unquote(e.Value)
				return v
			}
		case *ast.Ident:
			if expr, ok := constants[e.Name]; ok {
				return value(expr, depth+1)
			}
		case *ast.BinaryExpr:
			if e.Op == token.ADD {
				return value(e.X, depth+1) + value(e.Y, depth+1)
			}
		}
		return ""
	}
	hasSelector := func(parts []string) bool {
		for i, part := range parts {
			if part == "-L" && i+1 < len(parts) && parts[i+1] == "default" {
				return true
			}
		}
		return false
	}
	cleanPath := filepath.ToSlash(filepath.Clean(path))
	probeFile := cleanPath == "internal/tmux/default_probe.go" || cleanPath == "../../internal/tmux/default_probe.go"
	for _, decl := range file.Decls {
		scope := "package declaration"
		if fn, ok := decl.(*ast.FuncDecl); ok {
			scope = fn.Name.Name
		}
		allowedPath := probeFile && scope == "defaultSocketPath"
		reject := func() { findings = append(findings, fmt.Sprintf("%s builds a default selector", scope)) }
		ast.Inspect(decl, func(node ast.Node) bool {
			switch n := node.(type) {
			case *ast.BasicLit:
				if n.Kind != token.STRING {
					return true
				}
				text := value(n, 0)
				if hasSelector(strings.Fields(text)) || (!allowedPath && strings.HasSuffix(text, "/default")) {
					reject()
				}
			case *ast.CallExpr:
				name := ""
				switch f := n.Fun.(type) {
				case *ast.Ident:
					name = f.Name
				case *ast.SelectorExpr:
					name = f.Sel.Name
				}
				if name == "defaultSocketPath" {
					calls++
					if !probeFile || scope != "ProbeDefaultSessions" {
						reject()
					}
				}
				if name == "LegacyServer" {
					reject()
				}
				var args []string
				for _, arg := range n.Args {
					args = append(args, value(arg, 0))
				}
				if hasSelector(args) {
					reject()
				}
				if name == "Join" && len(args) > 0 && args[len(args)-1] == "default" && !allowedPath {
					reject()
				}
			case *ast.CompositeLit:
				var parts []string
				fields := map[string]string{}
				for _, element := range n.Elts {
					if kv, ok := element.(*ast.KeyValueExpr); ok {
						if key, ok := kv.Key.(*ast.Ident); ok {
							fields[key.Name] = value(kv.Value, 0)
						}
					} else {
						parts = append(parts, value(element, 0))
					}
				}
				if hasSelector(parts) || (fields["flag"] == "-L" && fields["name"] == "default") {
					reject()
				}
			}
			return true
		})
	}
	return findings, calls, nil
}

func TestDefaultSelectorScanCoversPackagesAndDeclarations(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name, path, source string
		want               bool
	}{
		{"package socket", "internal/message/selector.go", `package message; const socket="/tmp/tmux-42/default"`, true},
		{"other package function", "cmd/selector.go", `package cmd; func socket() string{return "/tmp/tmux-42/default"}`, true},
		{"label constant", "internal/message/selector.go", `package message; const label="default";var args=[]string{"-L",label}`, true},
		{"shell selector", "cmd/selector.go", `package cmd;const command="tmux -L default list-sessions"`, true},
		{"joined socket", "internal/state/selector.go", `package state;var socket=filepath.Join("/tmp","tmux-42","default")`, true},
		{"constructor constant", "internal/tmux/selector.go", `package tmux;const label="default";var server=Server{name:label,flag:"-L"}`, true},
		{"same name elsewhere", "cmd/internal/tmux/default_probe.go", `package message;func defaultSocketPath()string{return filepath.Join("/tmp","tmux-42","default")}`, true},
		{"named path builder", "internal/tmux/default_probe.go", `package tmux;func defaultSocketPath()string{return filepath.Join("/tmp","tmux-42","default")}`, false},
		{"label guard", "cmd/selector.go", `package cmd;func guard(label string)bool{return label=="default"}`, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			findings, _, err := defaultSelectorFindings(tc.path, []byte(tc.source))
			if err != nil {
				t.Fatal(err)
			}
			if (len(findings) > 0) != tc.want {
				t.Fatalf("findings=%v want rejection=%v", findings, tc.want)
			}
		})
	}
}
