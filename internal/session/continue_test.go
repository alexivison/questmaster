//go:build linux || darwin

package session

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/anthropics/ai-config/tools/party-cli/internal/state"
	"github.com/anthropics/ai-config/tools/party-cli/internal/tmux"
)

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

	masterID := "party-master"

	// Create master manifest with three workers.
	master := state.Manifest{
		PartyID:     masterID,
		SessionType: "master",
		Workers:     []string{"party-missing", "party-corrupt", "party-alive"},
	}
	if err := store.Create(master); err != nil {
		t.Fatal(err)
	}

	// party-missing: no manifest on disk (intentionally stopped) — should skip.
	// (no file created)

	// party-corrupt: invalid JSON at manifest path — should appear in failed.
	corruptPath := filepath.Join(storeDir, "party-corrupt.json")
	if err := os.WriteFile(corruptPath, []byte("{not valid json"), 0o644); err != nil {
		t.Fatal(err)
	}

	// party-alive: has manifest and tmux session — should skip (already running).
	aliveManifest := state.Manifest{PartyID: "party-alive"}
	aliveManifest.SetExtra("parent_session", masterID)
	if err := store.Create(aliveManifest); err != nil {
		t.Fatal(err)
	}

	runner := &testRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if args[0] == "has-session" {
			for i, a := range args {
				if a == "-t" && i+1 < len(args) && args[i+1] == "party-alive" {
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

	// party-missing should be skipped, NOT in failed.
	for _, f := range failed {
		if f == "party-missing" {
			t.Error("missing-manifest worker should be skipped, not marked as failed")
		}
	}

	// party-corrupt should be in failed.
	corruptFound := false
	for _, f := range failed {
		if f == "party-corrupt" {
			corruptFound = true
			break
		}
	}
	if !corruptFound {
		t.Error("corrupt-manifest worker should appear in failed list")
	}

	// party-alive should not be in failed (it's running).
	for _, f := range failed {
		if f == "party-alive" {
			t.Error("already-running worker should not appear in failed list")
		}
	}
}
