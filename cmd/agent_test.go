//go:build linux || darwin

package cmd

import (
	"bytes"
	"context"
	"os"
	"strings"
	"testing"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmuxroute"
	"github.com/spf13/cobra"
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
	if got := runAgentQuery(t, otherDir, "agent", "query", "names"); got != "claude\ncodex\nopencode\npi\n" {
		t.Fatalf("names used PARTY_REPO_ROOT unexpectedly: got %q", got)
	}
}

func TestAgentQuery_RemovesSingleValueQueries(t *testing.T) {
	for _, query := range []string{"roles", "primary-name", "agent-name"} {
		root := newAgentTestRoot(t)
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

	root := newAgentTestRoot(t)
	var out bytes.Buffer
	root.SetOut(&out)
	root.SetErr(&bytes.Buffer{})
	root.SetArgs(args)
	if err := root.Execute(); err != nil {
		t.Fatalf("Execute(%v): %v", args, err)
	}
	return out.String()
}

func newAgentTestRoot(t *testing.T) *cobra.Command {
	t.Helper()
	store := setupStore(t)
	client := tmux.NewClient(&mockRunner{fn: func(context.Context, ...string) (string, error) { return "", nil }})
	router := tmuxroute.New(store, map[string]*tmux.Client{"dev_previous": client}, func() string { return "dev_previous" }, nil)
	return NewRootCmd(WithDeps(store, client), WithTmuxRouter(router))
}

func TestAgentQueryNamesReflectAvailability(t *testing.T) {
	store := setupStore(t)
	if err := state.NewAgentAvailabilityStore(store.Root()).Set("codex", false); err != nil {
		t.Fatalf("disable codex: %v", err)
	}
	got := runCmd(t, store, &mockRunner{fn: func(context.Context, ...string) (string, error) { return "", nil }}, "agent", "query", "names")
	if got != "claude\nopencode\npi\n" {
		t.Fatalf("enabled names = %q, want claude/opencode/pi", got)
	}
}

func TestHiddenCodexSupervisorRespectsAvailability(t *testing.T) {
	store := setupStore(t)
	if err := state.NewAgentAvailabilityStore(store.Root()).Set("codex", false); err != nil {
		t.Fatalf("disable codex: %v", err)
	}
	_, err := runCmdErr(t, store, &mockRunner{fn: func(context.Context, ...string) (string, error) { return "", nil }}, "agent", "codex", "--binary", "/bin/false")
	if err == nil || !strings.Contains(err.Error(), `agent "codex" is disabled`) {
		t.Fatalf("hidden Codex supervisor with disabled codex = %v, want disabled error before runtime checks", err)
	}
}
