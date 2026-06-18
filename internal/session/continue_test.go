//go:build linux || darwin

package session

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
)

func TestContinue_MissingAgentBinaryErrorNamesOverrideAndFallback(t *testing.T) {
	t.Setenv("PATH", "/nonexistent")
	t.Setenv("CLAUDE_BIN", "")
	t.Setenv("HOME", t.TempDir())

	store, err := state.NewStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Create(state.Manifest{
		SessionID: "qm-missing-cli",
		Cwd:       t.TempDir(),
		Agents: []state.AgentManifest{
			{Name: "claude", Role: "primary", Window: 1},
		},
	}); err != nil {
		t.Fatal(err)
	}

	runner := &testRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) > 0 && args[0] == "has-session" {
			return "", &tmux.ExitError{Code: 1}
		}
		t.Fatalf("Continue should fail before invoking tmux command %v", args)
		return "", nil
	}}
	svc := &Service{
		Store:  store,
		Client: tmux.NewClient(runner),
	}

	_, err = svc.Continue(t.Context(), "qm-missing-cli")
	if err == nil {
		t.Fatal("Continue error = nil, want missing binary error")
	}

	msg := err.Error()
	for _, want := range []string{"claude CLI not found", `PATH lookup for "claude"`, "CLAUDE_BIN", "~/.local/bin/claude"} {
		if !strings.Contains(msg, want) {
			t.Fatalf("Continue error %q does not contain %q", msg, want)
		}
	}
}

// W3: cascadeWorkers should distinguish missing manifests (intentionally
// stopped workers) from corrupt manifests (unreadable data). Missing
// manifests are skipped silently; corrupt manifests are added to failed.
func TestCascadeWorkers_MissingVsCorruptManifest(t *testing.T) {
	t.Parallel()

	storeDir := t.TempDir()
	store, err := state.NewStore(storeDir)
	if err != nil {
		t.Fatal(err)
	}

	masterID := "qm-master"

	// Create master manifest with three workers.
	master := state.Manifest{
		SessionID:   masterID,
		SessionType: "master",
		Workers:     []string{"qm-missing", "qm-corrupt", "qm-alive"},
	}
	if err := store.Create(master); err != nil {
		t.Fatal(err)
	}

	// qm-missing: no manifest on disk (intentionally stopped) — should skip.
	// (no file created)

	// qm-corrupt: invalid JSON at manifest path — should appear in failed.
	corruptPath := filepath.Join(storeDir, "qm-corrupt.json")
	if err := os.WriteFile(corruptPath, []byte("{not valid json"), 0o644); err != nil {
		t.Fatal(err)
	}

	// qm-alive: has manifest and tmux session — should skip (already running).
	aliveManifest := state.Manifest{SessionID: "qm-alive"}
	aliveManifest.SetExtra("parent_session", masterID)
	if err := store.Create(aliveManifest); err != nil {
		t.Fatal(err)
	}

	runner := &testRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if args[0] == "has-session" {
			for i, a := range args {
				if a == "-t" && i+1 < len(args) && args[i+1] == "qm-alive" {
					return "", nil // alive session exists
				}
			}
			return "", &tmux.ExitError{Code: 1} // session doesn't exist
		}
		return "", nil
	}}

	svc := &Service{
		Store:       store,
		Client:      tmux.NewClient(runner),
		CLIResolver: func(string) (string, error) { return "echo noop", nil },
		Now:         func() int64 { return 200 },
		RandSuffix:  func() int64 { return 99 },
	}

	_, failed := svc.cascadeWorkers(t.Context(), masterID)

	// qm-missing should be skipped, NOT in failed.
	for _, f := range failed {
		if f == "qm-missing" {
			t.Error("missing-manifest worker should be skipped, not marked as failed")
		}
	}

	// qm-corrupt should be in failed.
	corruptFound := false
	for _, f := range failed {
		if f == "qm-corrupt" {
			corruptFound = true
			break
		}
	}
	if !corruptFound {
		t.Error("corrupt-manifest worker should appear in failed list")
	}

	// qm-alive should not be in failed (it's running).
	for _, f := range failed {
		if f == "qm-alive" {
			t.Error("already-running worker should not appear in failed list")
		}
	}
}
