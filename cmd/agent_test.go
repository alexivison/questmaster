//go:build linux || darwin

package cmd

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexivison/questmaster/internal/agentavailability"
	"github.com/alexivison/questmaster/internal/codexnative"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmuxroute"
	"github.com/spf13/cobra"
)

func TestAgentQuery_DefaultConfig(t *testing.T) {
	cwd := t.TempDir()

	if got := runAgentQuery(t, cwd, "agent", "query", "names"); got != "claude\ncodex\npi\n" {
		t.Fatalf("names = %q, want %q", got, "claude\ncodex\npi\n")
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
	if got := runAgentQuery(t, otherDir, "agent", "query", "names"); got != "claude\ncodex\npi\n" {
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
	if got != "claude\npi\n" {
		t.Fatalf("enabled names = %q, want claude/pi", got)
	}
}

func TestHiddenCodexSupervisorLaunchesAfterAdmissionThenDisable(t *testing.T) {
	store := setupStore(t)
	if err := agentavailability.RequireLaunch(store.Root(), "codex"); err != nil {
		t.Fatalf("lifecycle admission: %v", err)
	}

	runtimeDir := t.TempDir()
	if err := os.Chmod(runtimeDir, 0o700); err != nil {
		t.Fatalf("restrict runtime directory: %v", err)
	}
	if err := state.WriteRuntimeFile(runtimeDir, codexnative.MarkerName, []byte("1\n")); err != nil {
		t.Fatalf("prepare native runtime: %v", err)
	}
	t.Setenv(state.RuntimeDirEnv, runtimeDir)

	// Exercise the CLI boundary. The native supervisor's own tests cover the app-server and TUI lifecycle.
	fakeBinary := filepath.Join(t.TempDir(), "codex")
	if err := os.WriteFile(fakeBinary, []byte("#!/bin/sh\nexit 17\n"), 0o700); err != nil {
		t.Fatalf("write fake Codex executable: %v", err)
	}

	availability := state.NewAgentAvailabilityStore(store.Root())
	if err := availability.Set("codex", false); err != nil {
		t.Fatalf("disable codex after admission: %v", err)
	}

	runner := &mockRunner{fn: func(context.Context, ...string) (string, error) { return "", nil }}
	_, err := runCmdErr(t, store, runner, "agent", "codex", "--binary", fakeBinary)
	if err == nil || !strings.Contains(err.Error(), "Codex app-server startup: server exited: exit status 17") {
		t.Fatalf("supervisor did not launch the fake app-server after admission: %v", err)
	}
}
