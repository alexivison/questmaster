//go:build linux || darwin

package cmd

import (
	"context"
	"strings"
	"testing"

	"github.com/anthropics/ai-party/tools/party-cli/internal/tmux"
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
			// Distinguish session-name query from pane idle check.
			// Idle check uses -t <target> -p #{pane_in_mode}.
			for _, a := range args {
				if a == "#{pane_in_mode}" {
					return "0", nil // pane idle
				}
			}
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
			return "1 0 primary", nil
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
	t.Setenv("PARTY_SESSION", "") // ensure tmux mock path
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
	t.Setenv("PARTY_SESSION", "")
	store := setupStore(t)
	createManifest(t, store, "party-regular", "regular", "/tmp", "regular")

	// Auto-discover should fail because session is not a master
	_, err := runCmdErr(t, store, displayRunner("party-regular"), "broadcast", "hello")
	if err == nil {
		t.Fatal("expected error for non-master session")
	}
}

func TestBroadcastCmd_AutoDiscover_NotParty(t *testing.T) {
	t.Setenv("PARTY_SESSION", "")
	store := setupStore(t)

	_, err := runCmdErr(t, store, displayRunner("dev"), "broadcast", "hello")
	if err == nil {
		t.Fatal("expected error for non-party session")
	}
}

// ---------------------------------------------------------------------------
// PARTY_SESSION env var override tests
// ---------------------------------------------------------------------------

func TestBroadcastCmd_PartySessionOverride(t *testing.T) {
	t.Setenv("PARTY_SESSION", "party-master")
	store := setupStore(t)
	createManifest(t, store, "party-master", "master", "/tmp", "master")
	createWorkerManifest(t, store, "party-w1", "party-master")

	// displayRunner returns "party-other" but PARTY_SESSION should take precedence
	out := runCmd(t, store, displayRunner("party-other", "party-w1"), "broadcast", "hello all")
	if !strings.Contains(out, "1") {
		t.Fatalf("expected broadcast to 1 worker via PARTY_SESSION override, got: %s", out)
	}
}

// ---------------------------------------------------------------------------
// workers auto-discover tests
// ---------------------------------------------------------------------------

func TestWorkersCmd_AutoDiscover_Success(t *testing.T) {
	t.Setenv("PARTY_SESSION", "")
	store := setupStore(t)
	createManifest(t, store, "party-master", "master", "/tmp", "master")
	createWorkerManifest(t, store, "party-w1", "party-master")

	out := runCmd(t, store, displayRunner("party-master", "party-w1"), "workers")
	if !strings.Contains(out, "party-w1") {
		t.Fatalf("expected party-w1 in output, got: %s", out)
	}
}

func TestWorkersCmd_AutoDiscover_NotMaster(t *testing.T) {
	t.Setenv("PARTY_SESSION", "")
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
	t.Setenv("PARTY_SESSION", "")
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
	t.Setenv("PARTY_SESSION", "")
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
	store := setupStore(t)
	cwd := t.TempDir()
	writeAgentConfig(t, cwd)

	// Verify --attach is accepted by cobra. The actual attach needs a live tmux
	// server, so we tolerate runtime errors — only flag-parsing failures are bugs.
	_, err := runCmdErr(t, store, allPassRunner(), "start", "--cwd", cwd, "--attach", "test-title")
	if err != nil && strings.Contains(err.Error(), "unknown flag") {
		t.Fatalf("--attach flag not recognized by cobra: %v", err)
	}
}

func TestStartCmd_NoAttachByDefault(t *testing.T) {
	store := setupStore(t)
	cwd := t.TempDir()
	writeAgentConfig(t, cwd)

	// Without --attach, session starts without attach attempt
	out := runCmd(t, store, allPassRunner(), "start", "--cwd", cwd, "test-title")
	if !strings.Contains(out, "started") {
		t.Fatalf("expected 'started' in output, got: %s", out)
	}
}
