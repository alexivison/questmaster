package main

import (
	"bytes"
	"strings"
	"testing"

	"github.com/alexivison/questmaster/internal/state"
)

func runRoot(t *testing.T, args ...string) string {
	t.Helper()
	root := NewRootCmd()
	var out bytes.Buffer
	root.SetOut(&out)
	root.SetErr(&out)
	root.SetArgs(args)
	if err := root.Execute(); err != nil {
		t.Fatalf("execute %v: %v", args, err)
	}
	return out.String()
}

func TestVersionCommand(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	out := runRoot(t, "version")
	if !strings.HasPrefix(out, "quests ") {
		t.Errorf("version output = %q, want prefix %q", out, "quests ")
	}
}

func TestBarePrintsCockpitPlaceholder(t *testing.T) {
	home := t.TempDir()
	t.Setenv("QUESTS_HOME", home)
	out := runRoot(t)
	if !strings.Contains(out, "cockpit TODO") {
		t.Errorf("bare command output = %q, want it to mention the cockpit placeholder", out)
	}
	if !strings.Contains(out, home) {
		t.Errorf("bare command output = %q, want it to show resolved home %q", out, home)
	}
}

// TestBootstrapInjectsIsolatedStateRoot asserts the root exports the Quests
// state root into the spine's env var, distinct from questmaster's default.
func TestBootstrapInjectsIsolatedStateRoot(t *testing.T) {
	home := t.TempDir()
	t.Setenv("QUESTS_HOME", home)
	t.Setenv(state.StateRootEnv, "") // start clean

	runRoot(t, "version")

	got := state.StateRoot()
	want := home + "/state"
	if got != want {
		t.Errorf("state root after bootstrap = %q, want %q", got, want)
	}
	if strings.Contains(got, ".questmaster-state") {
		t.Errorf("quests state root %q must not be questmaster's", got)
	}
}
