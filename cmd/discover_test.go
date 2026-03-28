//go:build linux || darwin

package cmd

import (
	"context"
	"strings"
	"testing"

	"github.com/anthropics/ai-config/tools/party-cli/internal/tmux"
)

// displayRunner returns a mock that reports a session name for display-message
// and responds to has-session/list-sessions.
func displayRunner(sessionName string, live ...string) *mockRunner {
	liveSet := make(map[string]bool)
	for _, s := range live {
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
		if len(args) >= 1 && args[0] == "list-sessions" {
			if len(live) == 0 {
				return "", &tmux.ExitError{Code: 1}
			}
			return strings.Join(live, "\n"), nil
		}
		if len(args) >= 1 && args[0] == "list-panes" {
			return "1 0 claude", nil
		}
		if len(args) >= 1 && args[0] == "send-keys" {
			return "", nil
		}
		if len(args) >= 1 && args[0] == "capture-pane" {
			return "captured", nil
		}
		return "", nil
	}}
}

// ---------------------------------------------------------------------------
// broadcast auto-discover tests
// ---------------------------------------------------------------------------

func TestBroadcastCmd_AutoDiscover_Success(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "party-master", "master", "/tmp", "master")
	createWorkerManifest(t, store, "party-w1", "party-master")

	// Omit master-id — should auto-discover via display-message
	out := runCmd(t, store, displayRunner("party-master", "party-w1"), "broadcast", "hello all")
	if !strings.Contains(out, "1") {
		t.Fatalf("expected broadcast to 1 worker, got: %s", out)
	}
}

func TestBroadcastCmd_AutoDiscover_NotMaster(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "party-regular", "regular", "/tmp", "regular")

	// Auto-discover should fail because session is not a master
	_, err := runCmdErr(t, store, displayRunner("party-regular"), "broadcast", "hello")
	if err == nil {
		t.Fatal("expected error for non-master session")
	}
}

func TestBroadcastCmd_AutoDiscover_NotParty(t *testing.T) {
	t.Parallel()
	store := setupStore(t)

	_, err := runCmdErr(t, store, displayRunner("dev"), "broadcast", "hello")
	if err == nil {
		t.Fatal("expected error for non-party session")
	}
}

// ---------------------------------------------------------------------------
// workers auto-discover tests
// ---------------------------------------------------------------------------

func TestWorkersCmd_AutoDiscover_Success(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "party-master", "master", "/tmp", "master")
	createWorkerManifest(t, store, "party-w1", "party-master")

	out := runCmd(t, store, displayRunner("party-master", "party-w1"), "workers")
	if !strings.Contains(out, "party-w1") {
		t.Fatalf("expected party-w1 in output, got: %s", out)
	}
}

func TestWorkersCmd_AutoDiscover_NotMaster(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "party-regular", "regular", "/tmp", "regular")

	_, err := runCmdErr(t, store, displayRunner("party-regular"), "workers")
	if err == nil {
		t.Fatal("expected error for non-master session")
	}
}

// ---------------------------------------------------------------------------
// report auto-discover tests
// ---------------------------------------------------------------------------

func TestReportCmd_AutoDiscover_Success(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "party-master", "master", "/tmp", "master")
	createWorkerManifest(t, store, "party-w1", "party-master")

	// Omit session-id — should auto-discover as party-w1
	out := runCmd(t, store, displayRunner("party-w1", "party-master"), "report", "done: fixed it")
	if !strings.Contains(out, "Reported") {
		t.Fatalf("expected report confirmation, got: %s", out)
	}
}

func TestReportCmd_AutoDiscover_NotParty(t *testing.T) {
	t.Parallel()
	store := setupStore(t)

	_, err := runCmdErr(t, store, displayRunner("dev"), "report", "hello")
	if err == nil {
		t.Fatal("expected error for non-party session")
	}
}

// ---------------------------------------------------------------------------
// start --attach tests (cobra wiring only — attach itself needs tmux)
// ---------------------------------------------------------------------------

func TestStartCmd_AttachFlag_Accepted(t *testing.T) {
	t.Parallel()
	store := setupStore(t)

	// start with --attach should parse without error (attach will fail without tmux,
	// but the flag should be accepted by cobra)
	out := runCmd(t, store, allPassRunner(), "start", "--cwd", t.TempDir(), "--attach", "test-title")
	if !strings.Contains(out, "started") {
		t.Fatalf("expected 'started' in output, got: %s", out)
	}
}

func TestStartCmd_NoAttachByDefault(t *testing.T) {
	t.Parallel()
	store := setupStore(t)

	// Without --attach, session starts without attach attempt
	out := runCmd(t, store, allPassRunner(), "start", "--cwd", t.TempDir(), "test-title")
	if !strings.Contains(out, "started") {
		t.Fatalf("expected 'started' in output, got: %s", out)
	}
}
