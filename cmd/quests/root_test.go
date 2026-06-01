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

func TestBareLaunchesCockpit(t *testing.T) {
	t.Setenv("QUESTS_HOME", t.TempDir())

	launched := false
	e := defaultEnv()
	e.launchTUI = func() error { launched = true; return nil }

	root := newRootCmdWithEnv(e)
	root.SetArgs(nil)
	if err := root.Execute(); err != nil {
		t.Fatalf("bare command: %v", err)
	}
	if !launched {
		t.Error("bare command should launch the cockpit")
	}
	// The namespace must have been resolved before launch.
	if e.paths.Home == "" {
		t.Error("bootstrap should resolve paths before launching the cockpit")
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
