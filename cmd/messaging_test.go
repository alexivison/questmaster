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

// ---------------------------------------------------------------------------
// Helpers for messaging tests
// ---------------------------------------------------------------------------

func createWorkerManifest(t *testing.T, store *state.Store, id, parentID string) {
	t.Helper()
	m := state.Manifest{
		PartyID: id,
		Title:   id,
		Cwd:     "/tmp",
		Extra: map[string]json.RawMessage{
			"parent_session": json.RawMessage(`"` + parentID + `"`),
		},
	}
	if err := store.Create(m); err != nil {
		t.Fatalf("create worker manifest %s: %v", id, err)
	}
	if err := store.AddWorker(parentID, id); err != nil {
		t.Fatalf("add worker %s to %s: %v", id, parentID, err)
	}
}

// messagingRunner simulates live sessions with idle Claude panes.
func messagingRunner(live ...string) *mockRunner {
	liveSet := make(map[string]bool)
	for _, s := range live {
		liveSet[s] = true
	}
	return &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) >= 1 && args[0] == "has-session" {
			target := args[len(args)-1]
			if liveSet[target] {
				return "", nil
			}
			return "", &tmux.ExitError{Code: 1}
		}
		if len(args) >= 1 && args[0] == "list-panes" {
			return "1 0 claude", nil
		}
		if len(args) >= 1 && args[0] == "display-message" {
			return "0", nil // pane idle
		}
		if len(args) >= 1 && args[0] == "send-keys" {
			return "", nil
		}
		if len(args) >= 1 && args[0] == "capture-pane" {
			return "captured output line 1\ncaptured output line 2", nil
		}
		return "", &tmux.ExitError{Code: 1}
	}}
}

// ---------------------------------------------------------------------------
// relay command tests
// ---------------------------------------------------------------------------

func TestRelayCmd_Success(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "party-w1", "worker1", "/tmp", "")

	out := runCmd(t, store, messagingRunner("party-w1"), "relay", "party-w1", "hello worker")
	if !strings.Contains(out, "Delivered") {
		t.Fatalf("expected delivery confirmation, got: %s", out)
	}
}

func TestRelayCmd_MissingArgs(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	_, err := runCmdErr(t, store, messagingRunner(), "relay")
	if err == nil {
		t.Fatal("expected error for missing args")
	}
}

func TestRelayCmd_SessionNotRunning(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "party-w1", "worker1", "/tmp", "")

	_, err := runCmdErr(t, store, messagingRunner(), "relay", "party-w1", "hello")
	if err == nil {
		t.Fatal("expected error when session not running")
	}
}

// ---------------------------------------------------------------------------
// broadcast command tests
// ---------------------------------------------------------------------------

func TestBroadcastCmd_Success(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "party-master", "master", "/tmp", "master")
	createWorkerManifest(t, store, "party-w1", "party-master")
	createWorkerManifest(t, store, "party-w2", "party-master")

	out := runCmd(t, store, messagingRunner("party-w1", "party-w2"), "broadcast", "party-master", "hello all")
	if !strings.Contains(out, "2") {
		t.Fatalf("expected broadcast count of 2, got: %s", out)
	}
}

func TestBroadcastCmd_NoWorkers_MatchesShellOutput(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "party-master", "master", "/tmp", "master")

	out := runCmd(t, store, messagingRunner(), "broadcast", "party-master", "hello")
	if !strings.Contains(out, "No workers to broadcast to.") {
		t.Fatalf("expected shell-compatible zero-worker message, got: %s", out)
	}
}

func TestBroadcastCmd_RegisteredButDeadWorkers(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "party-master", "master", "/tmp", "master")
	createWorkerManifest(t, store, "party-w1", "party-master")

	// No live sessions — worker is dead
	out := runCmd(t, store, messagingRunner(), "broadcast", "party-master", "hello")
	if !strings.Contains(out, "Broadcast sent to 0 worker(s).") {
		t.Fatalf("expected 'Broadcast sent to 0' for dead workers, got: %s", out)
	}
}

func TestBroadcastCmd_MissingArgs(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	_, err := runCmdErr(t, store, messagingRunner(), "broadcast")
	if err == nil {
		t.Fatal("expected error for missing args")
	}
}

// ---------------------------------------------------------------------------
// read command tests
// ---------------------------------------------------------------------------

func TestReadCmd_Success(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "party-w1", "worker1", "/tmp", "")

	out := runCmd(t, store, messagingRunner("party-w1"), "read", "party-w1")
	if !strings.Contains(out, "captured output") {
		t.Fatalf("expected captured output, got: %s", out)
	}
}

func TestReadCmd_WithLinesFlag(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "party-w1", "worker1", "/tmp", "")

	out := runCmd(t, store, messagingRunner("party-w1"), "read", "party-w1", "--lines", "200")
	if !strings.Contains(out, "captured output") {
		t.Fatalf("expected captured output, got: %s", out)
	}
}

func TestReadCmd_MissingArgs(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	_, err := runCmdErr(t, store, messagingRunner(), "read")
	if err == nil {
		t.Fatal("expected error for missing args")
	}
}

// ---------------------------------------------------------------------------
// report command tests
// ---------------------------------------------------------------------------

func TestReportCmd_Success(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "party-master", "master", "/tmp", "master")
	createWorkerManifest(t, store, "party-w1", "party-master")

	out := runCmd(t, store, messagingRunner("party-master"), "report", "party-w1", "done: fixed it")
	if !strings.Contains(out, "Reported") {
		t.Fatalf("expected report confirmation, got: %s", out)
	}
}

func TestReportCmd_MissingArgs(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	_, err := runCmdErr(t, store, messagingRunner(), "report")
	if err == nil {
		t.Fatal("expected error for missing args")
	}
}

// ---------------------------------------------------------------------------
// workers command tests
// ---------------------------------------------------------------------------

func TestWorkersCmd_OutputFormat(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "party-master", "master", "/tmp", "master")
	createWorkerManifest(t, store, "party-w1", "party-master")
	createWorkerManifest(t, store, "party-w2", "party-master")

	out := runCmd(t, store, messagingRunner("party-w1"), "workers", "party-master")
	if !strings.Contains(out, "SESSION") {
		t.Fatalf("expected header row, got: %s", out)
	}
	if !strings.Contains(out, "party-w1") {
		t.Fatalf("expected party-w1 in output, got: %s", out)
	}
	if !strings.Contains(out, "party-w2") {
		t.Fatalf("expected party-w2 in output, got: %s", out)
	}
	if !strings.Contains(out, "active") {
		t.Fatalf("expected 'active' status, got: %s", out)
	}
	if !strings.Contains(out, "stopped") {
		t.Fatalf("expected 'stopped' status, got: %s", out)
	}
}

func TestWorkersCmd_NoWorkers(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "party-master", "master", "/tmp", "master")

	out := runCmd(t, store, messagingRunner(), "workers", "party-master")
	if !strings.Contains(out, "No workers") {
		t.Fatalf("expected 'No workers' message, got: %s", out)
	}
}

func TestWorkersCmd_MissingArgs(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	_, err := runCmdErr(t, store, messagingRunner(), "workers")
	if err == nil {
		t.Fatal("expected error for missing args")
	}
}
