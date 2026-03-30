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

// W2: stopOne swallows manifest deletion errors with _ = s.Store.Delete().
// When deletion fails (e.g., I/O error), the stale manifest silently lingers.
func TestStopOne_PropagatesDeleteError(t *testing.T) {
	t.Parallel()

	storeDir := t.TempDir()
	store, err := state.NewStore(storeDir)
	if err != nil {
		t.Fatal(err)
	}

	sessionID := "party-stoptest"

	// Create a non-empty directory at the manifest path so os.Remove
	// fails with ENOTEMPTY — a real deletion error, not "not found".
	manifestPath := filepath.Join(storeDir, sessionID+".json")
	if err := os.MkdirAll(filepath.Join(manifestPath, "blocker"), 0o755); err != nil {
		t.Fatal(err)
	}

	runner := &testRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if args[0] == "kill-session" {
			return "", nil
		}
		return "", &tmux.ExitError{Code: 1}
	}}

	svc := &Service{
		Store:  store,
		Client: tmux.NewClient(runner),
	}

	err = svc.stopOne(t.Context(), sessionID)
	if err == nil {
		t.Error("expected error when manifest deletion fails, got nil")
	}
}

// W2: Delete also swallows manifest deletion errors.
func TestDelete_PropagatesDeleteError(t *testing.T) {
	t.Parallel()

	storeDir := t.TempDir()
	store, err := state.NewStore(storeDir)
	if err != nil {
		t.Fatal(err)
	}

	sessionID := "party-deltest"

	manifestPath := filepath.Join(storeDir, sessionID+".json")
	if err := os.MkdirAll(filepath.Join(manifestPath, "blocker"), 0o755); err != nil {
		t.Fatal(err)
	}

	runner := &testRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if args[0] == "kill-session" {
			return "", nil
		}
		return "", &tmux.ExitError{Code: 1}
	}}

	svc := &Service{
		Store:  store,
		Client: tmux.NewClient(runner),
	}

	err = svc.Delete(t.Context(), sessionID)
	if err == nil {
		t.Error("expected error when manifest deletion fails, got nil")
	}
}
