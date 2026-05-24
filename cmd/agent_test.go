//go:build linux || darwin

package cmd

import (
	"bytes"
	"os"
	"testing"
)

func TestAgentQuery_DefaultConfig(t *testing.T) {
	cwd := t.TempDir()

	if got := runAgentQuery(t, cwd, "agent", "query", "roles"); got != "primary\n" {
		t.Fatalf("roles = %q, want %q", got, "primary\n")
	}
	if got := runAgentQuery(t, cwd, "agent", "query", "names"); got != "claude\ncodex\npi\n" {
		t.Fatalf("names = %q, want %q", got, "claude\ncodex\npi\n")
	}
	if got := runAgentQuery(t, cwd, "agent", "query", "primary-name"); got != "claude\n" {
		t.Fatalf("primary-name = %q, want %q", got, "claude\n")
	}
}

func TestAgentQuery_RepoRootOverride(t *testing.T) {
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

	root := NewRootCmd(WithTUILauncher(func() error { return nil }))
	var out bytes.Buffer
	root.SetOut(&out)
	root.SetErr(&bytes.Buffer{})
	root.SetArgs([]string{"agent", "query", "primary-name"})
	if err := root.Execute(); err != nil {
		t.Fatalf("Execute(agent query primary-name): %v", err)
	}
	if got := out.String(); got != "claude\n" {
		t.Fatalf("primary-name used PARTY_REPO_ROOT unexpectedly: got %q, want claude", got)
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

	root := NewRootCmd(WithTUILauncher(func() error { return nil }))
	var out bytes.Buffer
	root.SetOut(&out)
	root.SetErr(&bytes.Buffer{})
	root.SetArgs(args)
	if err := root.Execute(); err != nil {
		t.Fatalf("Execute(%v): %v", args, err)
	}
	return out.String()
}
