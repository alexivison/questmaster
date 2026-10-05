//go:build linux || darwin

package cmd

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
)

// ---------------------------------------------------------------------------
// Helpers for messaging tests
// ---------------------------------------------------------------------------

func createWorkerManifest(t *testing.T, store *state.Store, id, parentID string) {
	t.Helper()
	m := state.Manifest{
		SessionID: id,
		Title:     id,
		Cwd:       "/tmp",
		Agents: []state.AgentManifest{
			{Name: "claude", Role: "primary", CLI: "/usr/bin/claude", Window: 1},
		},
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

// messagingRunner simulates live sessions with idle primary panes.
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
			return "1 0 primary", nil
		}
		if len(args) >= 1 && args[0] == "display-message" {
			return "0", nil // pane idle
		}
		if len(args) >= 1 && args[0] == "send-keys" {
			return "", nil
		}
		if len(args) >= 1 && args[0] == "capture-pane" {
			return "⏺ captured output line 1\n⎿ captured output line 2", nil
		}
		return "", &tmux.ExitError{Code: 1}
	}}
}

type sendCaptureRunner struct {
	live  map[string]bool
	sends []string
}

func newSendCaptureRunner(live ...string) *sendCaptureRunner {
	liveSet := make(map[string]bool, len(live))
	for _, s := range live {
		liveSet[s] = true
	}
	return &sendCaptureRunner{live: liveSet}
}

func (r *sendCaptureRunner) Run(_ context.Context, args ...string) (string, error) {
	if len(args) >= 1 && args[0] == "has-session" {
		target := args[len(args)-1]
		if r.live[target] {
			return "", nil
		}
		return "", &tmux.ExitError{Code: 1}
	}
	if len(args) >= 1 && args[0] == "list-panes" {
		return "1 0 primary", nil
	}
	if len(args) >= 1 && args[0] == "display-message" {
		if len(args) > 0 && args[len(args)-1] == "#{session_name}" {
			return "", &tmux.ExitError{Code: 1}
		}
		return "0", nil
	}
	if len(args) >= 1 && args[0] == "send-keys" {
		if len(args) >= 2 && args[len(args)-1] != "Enter" {
			r.sends = append(r.sends, args[len(args)-1])
		}
		return "", nil
	}
	if len(args) >= 1 && args[0] == "capture-pane" {
		return "captured output", nil
	}
	return "", &tmux.ExitError{Code: 1}
}

// ---------------------------------------------------------------------------
// read command tests
// ---------------------------------------------------------------------------

func TestReadCmd_Success(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-w1", "worker1", "/tmp", "")

	out := runCmd(t, store, messagingRunner("qm-w1"), "read", "qm-w1")
	var got struct {
		WorkerID string `json:"worker_id"`
		Output   string `json:"output"`
	}
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("read output is not JSON: %v\n%s", err, out)
	}
	if got.WorkerID != "qm-w1" || !strings.Contains(got.Output, "captured output") {
		t.Fatalf("read JSON mismatch: %#v", got)
	}
}

func TestReadCmd_WithLinesFlag(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-w1", "worker1", "/tmp", "")

	out := runCmd(t, store, messagingRunner("qm-w1"), "read", "qm-w1", "--lines", "200")
	var got struct {
		Output string `json:"output"`
	}
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("read output is not JSON: %v\n%s", err, out)
	}
	if !strings.Contains(got.Output, "captured output") {
		t.Fatalf("read JSON mismatch: %#v", got)
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
// workers command tests
// ---------------------------------------------------------------------------

func TestWorkersCmd_OutputFormat(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-master", "master", "/tmp", "master")
	createWorkerManifest(t, store, "qm-w1", "qm-master")
	createWorkerManifest(t, store, "qm-w2", "qm-master")

	out := runCmd(t, store, messagingRunner("qm-w1"), "workers", "qm-master")
	var got workersJSONOutput
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("workers output is not JSON: %v\n%s", err, out)
	}
	if len(got.Workers) != 2 {
		t.Fatalf("workers = %#v, want 2", got.Workers)
	}
	if got.Workers[0].SessionID != "qm-w1" || got.Workers[0].Status != "active" {
		t.Fatalf("worker 0 mismatch: %#v", got.Workers[0])
	}
	if got.Workers[1].SessionID != "qm-w2" || got.Workers[1].Status != "stopped" {
		t.Fatalf("worker 1 mismatch: %#v", got.Workers[1])
	}
}

func TestWorkersCmd_JSON(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-master", "master", "/tmp", "master")
	createWorkerManifest(t, store, "qm-w1", "qm-master")

	out := runCmd(t, store, messagingRunner("qm-w1"), "workers", "qm-master")

	var got struct {
		MasterID string `json:"master_id"`
		Workers  []struct {
			SessionID string `json:"session_id"`
			Status    string `json:"status"`
			Title     string `json:"title"`
		} `json:"workers"`
	}
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("workers output is not JSON: %v\n%s", err, out)
	}
	if got.MasterID != "qm-master" {
		t.Fatalf("master_id = %q, want qm-master", got.MasterID)
	}
	if len(got.Workers) != 1 || got.Workers[0].SessionID != "qm-w1" || got.Workers[0].Status != "active" {
		t.Fatalf("workers JSON mismatch: %#v", got.Workers)
	}
}

func TestWorkersCmd_NoWorkers(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-master", "master", "/tmp", "master")

	out := runCmd(t, store, messagingRunner(), "workers", "qm-master")
	var got workersJSONOutput
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("workers output is not JSON: %v\n%s", err, out)
	}
	if got.MasterID != "qm-master" || len(got.Workers) != 0 {
		t.Fatalf("workers JSON mismatch: %#v", got)
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
