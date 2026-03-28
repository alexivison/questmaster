//go:build linux || darwin

package cmd

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/anthropics/ai-config/tools/party-cli/internal/state"
	"github.com/anthropics/ai-config/tools/party-cli/internal/tmux"
)

// jumpMasterRunner simulates a tmux environment for jump-master tests.
// sessionName is what display-message returns as the current session.
// liveSessions are sessions that has-session succeeds for.
// switchErr controls whether switch-client fails.
func jumpMasterRunner(sessionName string, liveSessions []string, switchErr bool) *mockRunner {
	liveSet := make(map[string]bool)
	for _, s := range liveSessions {
		liveSet[s] = true
	}
	return &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) >= 1 && args[0] == "display-message" {
			return sessionName, nil
		}
		if len(args) >= 1 && args[0] == "has-session" {
			target := args[len(args)-1]
			if liveSet[target] {
				return "", nil
			}
			return "", &tmux.ExitError{Code: 1}
		}
		if len(args) >= 1 && args[0] == "switch-client" {
			if switchErr {
				return "", &tmux.ExitError{Code: 1}
			}
			return "", nil
		}
		if len(args) >= 1 && args[0] == "list-clients" {
			return "/dev/pts/0", nil
		}
		return "", &tmux.ExitError{Code: 1}
	}}
}

func TestJumpMaster_NotPartySession(t *testing.T) {
	t.Parallel()
	store := setupStore(t)

	out := runCmd(t, store, jumpMasterRunner("dev", nil, false), "jump-master")
	if !strings.Contains(out, "Not in a party session") {
		t.Fatalf("expected 'Not in a party session', got: %s", out)
	}
}

func TestJumpMaster_AlreadyMaster(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "party-master", "orch", "/tmp", "master")

	out := runCmd(t, store, jumpMasterRunner("party-master", nil, false), "jump-master")
	if !strings.Contains(out, "Already in master session") {
		t.Fatalf("expected 'Already in master session', got: %s", out)
	}
}

func TestJumpMaster_NoParent(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "party-worker", "worker", "/tmp", "regular")

	out := runCmd(t, store, jumpMasterRunner("party-worker", nil, false), "jump-master")
	if !strings.Contains(out, "No parent master session found") {
		t.Fatalf("expected 'No parent master session found', got: %s", out)
	}
}

func TestJumpMaster_ParentNotRunning(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	// Create worker manifest with parent_session
	m := state.Manifest{
		PartyID: "party-worker",
		Title:   "worker",
		Cwd:     "/tmp",
		Extra: map[string]json.RawMessage{
			"parent_session": json.RawMessage(`"party-master"`),
		},
	}
	if err := store.Create(m); err != nil {
		t.Fatal(err)
	}

	// Master is not in the live sessions list
	out := runCmd(t, store, jumpMasterRunner("party-worker", nil, false), "jump-master")
	if !strings.Contains(out, "is not running") {
		t.Fatalf("expected 'is not running', got: %s", out)
	}
}

func TestJumpMaster_Success(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "party-master", "orch", "/tmp", "master")
	m := state.Manifest{
		PartyID: "party-worker",
		Title:   "worker",
		Cwd:     "/tmp",
		Extra: map[string]json.RawMessage{
			"parent_session": json.RawMessage(`"party-master"`),
		},
	}
	if err := store.Create(m); err != nil {
		t.Fatal(err)
	}

	// Master is running, switch should succeed
	out := runCmd(t, store, jumpMasterRunner("party-worker", []string{"party-master"}, false), "jump-master")
	// No output on success (switch-client is silent)
	if strings.Contains(out, "error") || strings.Contains(out, "Error") {
		t.Fatalf("expected no error, got: %s", out)
	}
}

func TestJumpMaster_NoManifest(t *testing.T) {
	t.Parallel()
	store := setupStore(t)

	// party-orphan has no manifest
	out := runCmd(t, store, jumpMasterRunner("party-orphan", nil, false), "jump-master")
	if !strings.Contains(out, "No parent master session found") {
		t.Fatalf("expected 'No parent master session found', got: %s", out)
	}
}
