//go:build linux || darwin

package cmd

import (
	"context"
	"strings"
	"testing"

	"github.com/anthropics/ai-party/tools/party-cli/internal/tmux"
)

// allPassRunner returns a mock that accepts any tmux command and reports
// has-session as false (no existing sessions).
func allPassRunner() *mockRunner {
	return &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) > 0 && args[0] == "has-session" {
			return "", &tmux.ExitError{Code: 1}
		}
		if len(args) > 0 && args[0] == "list-sessions" {
			return "", &tmux.ExitError{Code: 1}
		}
		return "", nil
	}}
}

// hasSessionRunner returns a mock where has-session succeeds for the given sessions.
func hasSessionRunner(live ...string) *mockRunner {
	set := make(map[string]bool)
	for _, s := range live {
		set[s] = true
	}
	return &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) >= 3 && args[0] == "has-session" {
			if set[args[2]] {
				return "", nil
			}
			return "", &tmux.ExitError{Code: 1}
		}
		if len(args) >= 1 && args[0] == "list-sessions" {
			if len(live) == 0 {
				return "", &tmux.ExitError{Code: 1}
			}
			return strings.Join(live, "\n"), nil
		}
		return "", nil
	}}
}

// ---------------------------------------------------------------------------
// start command tests
// ---------------------------------------------------------------------------

func TestStartCmd_Basic(t *testing.T) {
	t.Parallel()
	store := setupStore(t)

	out := runCmd(t, store, allPassRunner(), "start", "--cwd", t.TempDir(), "test-title")
	if !strings.Contains(out, "started") {
		t.Fatalf("expected 'started' in output, got: %s", out)
	}
}

// Note: master start is tested at the session-service level (TestStart_Master)
// where CLIResolver is mockable. The cmd layer only verifies cobra wiring.

// ---------------------------------------------------------------------------
// continue command tests
// ---------------------------------------------------------------------------

func TestContinueCmd_AlreadyRunning(t *testing.T) {
	t.Parallel()
	store := setupStore(t)

	out := runCmd(t, store, hasSessionRunner("party-alive"), "continue", "party-alive")
	if !strings.Contains(out, "already running") {
		t.Fatalf("expected 'already running' message, got: %s", out)
	}
}

func TestContinueCmd_MissingManifest(t *testing.T) {
	t.Parallel()
	store := setupStore(t)

	_, err := runCmdErr(t, store, allPassRunner(), "continue", "party-ghost")
	if err == nil {
		t.Fatal("expected error for missing manifest")
	}
}

// ---------------------------------------------------------------------------
// stop command tests
// ---------------------------------------------------------------------------

func TestStopCmd_Single(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "party-victim", "doomed", t.TempDir(), "regular")

	out := runCmd(t, store, hasSessionRunner("party-victim"), "stop", "party-victim")
	if !strings.Contains(out, "Stopped: party-victim") {
		t.Fatalf("expected stopped message, got: %s", out)
	}
}

func TestStopCmd_NoSessions(t *testing.T) {
	t.Parallel()
	store := setupStore(t)

	out := runCmd(t, store, allPassRunner(), "stop")
	if !strings.Contains(out, "No active") {
		t.Fatalf("expected 'No active', got: %s", out)
	}
}

// ---------------------------------------------------------------------------
// delete command tests
// ---------------------------------------------------------------------------

func TestDeleteCmd_Basic(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "party-del", "deleteme", t.TempDir(), "regular")

	out := runCmd(t, store, hasSessionRunner("party-del"), "delete", "party-del")
	if !strings.Contains(out, "Deleted: party-del") {
		t.Fatalf("expected delete message, got: %s", out)
	}
}

func TestDeleteCmd_NoArgs(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	_, err := runCmdErr(t, store, allPassRunner(), "delete")
	if err == nil {
		t.Fatal("expected error with no args")
	}
}

// ---------------------------------------------------------------------------
// promote command tests
// ---------------------------------------------------------------------------

// Note: classic promote with full pane replacement is tested at the session-service
// level (TestPromote_Classic, TestPromote_Sidebar) where CLIResolver is mockable.

func TestPromoteCmd_AlreadyMaster(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "party-master", "orch", t.TempDir(), "master")

	out := runCmd(t, store, hasSessionRunner("party-master"), "promote", "party-master")
	if !strings.Contains(out, "promoted to master") {
		t.Fatalf("expected success (idempotent), got: %s", out)
	}
}

// ---------------------------------------------------------------------------
// spawn command tests
// ---------------------------------------------------------------------------

func TestSpawnCmd_Basic(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	cwd := t.TempDir()
	createManifest(t, store, "party-master", "orch", cwd, "master")

	out := runCmd(t, store, allPassRunner(), "spawn", "party-master", "worker-title")
	if !strings.Contains(out, "spawned") {
		t.Fatalf("expected 'spawned' in output, got: %s", out)
	}
}

func TestSpawnCmd_NonMaster(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "party-regular", "regular", t.TempDir(), "regular")

	_, err := runCmdErr(t, store, allPassRunner(), "spawn", "party-regular")
	if err == nil {
		t.Fatal("expected error spawning from non-master")
	}
}
