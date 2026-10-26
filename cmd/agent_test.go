//go:build linux || darwin

package cmd

import (
	"bytes"
	"os"
	"strings"
	"testing"
)

func TestAgentQuery_DefaultConfig(t *testing.T) {
	cwd := t.TempDir()

	if got := runAgentQuery(t, cwd, "agent", "query", "names"); got != "claude\ncodex\nopencode\npi\n" {
		t.Fatalf("names = %q, want %q", got, "claude\ncodex\nopencode\npi\n")
	}
}

func TestAgentQuery_NamesIgnoreRepoRoot(t *testing.T) {
	repoRoot := t.TempDir()

	otherDir := t.TempDir()
	previous, err := os.Getwd()
	if err != nil {
		t.Fatalf("Getwd: %v", err)
	}
	if err := os.Chdir(otherDir); err != nil {
		t.Fatalf("Chdir(%s): %v", otherDir, err)
	}
	defer func() {
		if chdirErr := os.Chdir(previous); chdirErr != nil {
			t.Fatalf("restore cwd: %v", chdirErr)
		}
	}()

	t.Setenv("PARTY_REPO_ROOT", repoRoot)

	root := NewRootCmd()
	var out bytes.Buffer
	root.SetOut(&out)
	root.SetErr(&bytes.Buffer{})
	root.SetArgs([]string{"agent", "query", "names"})
	if err := root.Execute(); err != nil {
		t.Fatalf("Execute(agent query names): %v", err)
	}
	if got := out.String(); got != "claude\ncodex\nopencode\npi\n" {
		t.Fatalf("names used PARTY_REPO_ROOT unexpectedly: got %q", got)
	}
}

func TestAgentQuery_RemovesSingleValueQueries(t *testing.T) {
	for _, query := range []string{"roles", "primary-name", "agent-name"} {
		root := NewRootCmd()
		root.SetErr(&bytes.Buffer{})
		root.SetArgs([]string{"agent", "query", query})
		if err := root.Execute(); err == nil || !strings.Contains(err.Error(), "unknown query") {
			t.Errorf("agent query %q error = %v, want unknown query", query, err)
		}
	}
}

func runAgentQuery(t *testing.T, cwd string, args ...string) string {
	t.Helper()

	previous, err := os.Getwd()
	if err != nil {
		t.Fatalf("Getwd: %v", err)
	}
	if err := os.Chdir(cwd); err != nil {
		t.Fatalf("Chdir(%s): %v", cwd, err)
	}
	defer func() {
		if chdirErr := os.Chdir(previous); chdirErr != nil {
			t.Fatalf("restore cwd: %v", chdirErr)
		}
	}()

	root := NewRootCmd()
	var out bytes.Buffer
	root.SetOut(&out)
	root.SetErr(&bytes.Buffer{})
	root.SetArgs(args)
	if err := root.Execute(); err != nil {
		t.Fatalf("Execute(%v): %v", args, err)
	}
	return out.String()
}
