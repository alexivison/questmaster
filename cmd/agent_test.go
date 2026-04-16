//go:build linux || darwin

package cmd

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/anthropics/ai-party/tools/party-cli/internal/tui"
)

func TestAgentQuery_DefaultConfig(t *testing.T) {
	cwd := t.TempDir()

	if got := runAgentQuery(t, cwd, "agent", "query", "roles"); got != "primary\ncompanion\n" {
		t.Fatalf("roles = %q, want %q", got, "primary\ncompanion\n")
	}
	if got := runAgentQuery(t, cwd, "agent", "query", "names"); got != "claude\ncodex\n" {
		t.Fatalf("names = %q, want %q", got, "claude\ncodex\n")
	}
	if got := runAgentQuery(t, cwd, "agent", "query", "primary-name"); got != "claude\n" {
		t.Fatalf("primary-name = %q, want %q", got, "claude\n")
	}
	if got := runAgentQuery(t, cwd, "agent", "query", "evidence-required"); got != "pr-verified\ncode-critic\nminimizer\ncodex\ntest-runner\ncheck-runner\n" {
		t.Fatalf("evidence-required = %q", got)
	}
}

func TestAgentQuery_NoCompanion(t *testing.T) {
	cwd := t.TempDir()
	writeAgentQueryConfig(t, "[roles.primary]\nagent = \"claude\"\n")

	if got := runAgentQuery(t, cwd, "agent", "query", "companion-name"); got != "" {
		t.Fatalf("companion-name = %q, want empty", got)
	}
	if got := runAgentQuery(t, cwd, "agent", "query", "evidence-required"); strings.Contains(got, "codex\n") {
		t.Fatalf("evidence-required should omit companion evidence, got %q", got)
	}
}

func TestAgentQuery_RepoRootOverride(t *testing.T) {
	repoRoot := t.TempDir()
	writeAgentQueryConfig(t, "[roles.primary]\nagent = \"claude\"\n")

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

	root := NewRootCmd(WithTUILauncher(func(...tui.Option) error { return nil }))
	var out bytes.Buffer
	root.SetOut(&out)
	root.SetErr(&bytes.Buffer{})
	root.SetArgs([]string{"agent", "query", "companion-name"})
	if err := root.Execute(); err != nil {
		t.Fatalf("Execute(agent query companion-name): %v", err)
	}
	if got := out.String(); got != "" {
		t.Fatalf("companion-name ignored user-global config and used PARTY_REPO_ROOT: got %q, want empty", got)
	}
}

func writeAgentQueryConfig(t *testing.T, body string) {
	t.Helper()

	configRoot := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", configRoot)

	configPath := filepath.Join(configRoot, "party-cli", "config.toml")
	if err := os.MkdirAll(filepath.Dir(configPath), 0o755); err != nil {
		t.Fatalf("mkdir config dir: %v", err)
	}
	if err := os.WriteFile(configPath, []byte(strings.TrimSpace(body)+"\n"), 0o644); err != nil {
		t.Fatalf("write config.toml: %v", err)
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

	root := NewRootCmd(WithTUILauncher(func(...tui.Option) error { return nil }))
	var out bytes.Buffer
	root.SetOut(&out)
	root.SetErr(&bytes.Buffer{})
	root.SetArgs(args)
	if err := root.Execute(); err != nil {
		t.Fatalf("Execute(%v): %v", args, err)
	}
	return out.String()
}
