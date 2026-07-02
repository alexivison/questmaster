//go:build linux || darwin

package cmd

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
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
// relay command tests
// ---------------------------------------------------------------------------

func TestRelayCmd_Success(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-w1", "worker1", "/tmp", "")

	out := runCmd(t, store, messagingRunner("qm-w1"), "relay", "qm-w1", "hello worker")
	var got struct {
		WorkerID  string `json:"worker_id"`
		Delivered bool   `json:"delivered"`
	}
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("relay output is not JSON: %v\n%s", err, out)
	}
	if got.WorkerID != "qm-w1" || !got.Delivered {
		t.Fatalf("relay JSON mismatch: %#v", got)
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
	createManifest(t, store, "qm-w1", "worker1", "/tmp", "")

	_, err := runCmdErr(t, store, messagingRunner(), "relay", "qm-w1", "hello")
	if err == nil {
		t.Fatal("expected error when session not running")
	}
}

func TestRelayCmd_ReadsMessageFileFromStdin(t *testing.T) {
	t.Setenv("QUESTMASTER_SESSION", "")
	store := setupStore(t)
	createManifest(t, store, "qm-w1", "worker1", "/tmp", "")
	runner := newSendCaptureRunner("qm-w1")

	out := runCmdInput(t, store, runner, strings.NewReader("from stdin"), "relay", "qm-w1", "--message-file", "-")
	var got struct {
		WorkerID  string `json:"worker_id"`
		Delivered bool   `json:"delivered"`
	}
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("relay output is not JSON: %v\n%s", err, out)
	}
	if got.WorkerID != "qm-w1" || !got.Delivered {
		t.Fatalf("relay JSON mismatch: %#v", got)
	}
	if len(runner.sends) != 1 || runner.sends[0] != "from stdin" {
		t.Fatalf("send payloads = %#v, want stdin body", runner.sends)
	}
}

func TestRelayCmd_RejectsMessageAndMessageFile(t *testing.T) {
	store := setupStore(t)
	createManifest(t, store, "qm-w1", "worker1", "/tmp", "")

	_, err := runCmdInputErr(t, store, messagingRunner("qm-w1"), strings.NewReader("from stdin"), "relay", "qm-w1", "inline", "--message-file", "-")
	if err == nil || !strings.Contains(err.Error(), "only one of message or --message-file") {
		t.Fatalf("relay with duplicate message sources error = %v", err)
	}
}

// ---------------------------------------------------------------------------
// broadcast command tests
// ---------------------------------------------------------------------------

func TestBroadcastCmd_Success(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-master", "master", "/tmp", "master")
	createWorkerManifest(t, store, "qm-w1", "qm-master")
	createWorkerManifest(t, store, "qm-w2", "qm-master")

	out := runCmd(t, store, messagingRunner("qm-w1", "qm-w2"), "broadcast", "qm-master", "hello all")
	var got struct {
		MasterID   string `json:"master_id"`
		Registered int    `json:"registered"`
		Delivered  int    `json:"delivered"`
	}
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("broadcast output is not JSON: %v\n%s", err, out)
	}
	if got.MasterID != "qm-master" || got.Registered != 2 || got.Delivered != 2 {
		t.Fatalf("broadcast JSON mismatch: %#v", got)
	}
}

func TestBroadcastCmd_NoWorkers_MatchesShellOutput(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-master", "master", "/tmp", "master")

	out := runCmd(t, store, messagingRunner(), "broadcast", "qm-master", "hello")
	var got struct {
		Registered int `json:"registered"`
		Delivered  int `json:"delivered"`
	}
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("broadcast output is not JSON: %v\n%s", err, out)
	}
	if got.Registered != 0 || got.Delivered != 0 {
		t.Fatalf("broadcast JSON mismatch: %#v", got)
	}
}

func TestBroadcastCmd_RegisteredButDeadWorkers(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-master", "master", "/tmp", "master")
	createWorkerManifest(t, store, "qm-w1", "qm-master")

	// No live sessions — worker is dead
	out := runCmd(t, store, messagingRunner(), "broadcast", "qm-master", "hello")
	var got struct {
		Registered int `json:"registered"`
		Delivered  int `json:"delivered"`
	}
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("broadcast output is not JSON: %v\n%s", err, out)
	}
	if got.Registered != 1 || got.Delivered != 0 {
		t.Fatalf("broadcast JSON mismatch: %#v", got)
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

func TestBroadcastCmd_ReadsMessageFile(t *testing.T) {
	t.Setenv("QUESTMASTER_SESSION", "")
	store := setupStore(t)
	createManifest(t, store, "qm-master", "master", "/tmp", "master")
	createWorkerManifest(t, store, "qm-w1", "qm-master")
	bodyPath := filepath.Join(t.TempDir(), "message.txt")
	if err := os.WriteFile(bodyPath, []byte("from file"), 0o644); err != nil {
		t.Fatalf("write message file: %v", err)
	}
	runner := newSendCaptureRunner("qm-w1")

	out := runCmd(t, store, runner, "broadcast", "qm-master", "--message-file", bodyPath)
	var got struct {
		Registered int `json:"registered"`
		Delivered  int `json:"delivered"`
	}
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("broadcast output is not JSON: %v\n%s", err, out)
	}
	if got.Registered != 1 || got.Delivered != 1 {
		t.Fatalf("broadcast JSON mismatch: %#v", got)
	}
	if len(runner.sends) != 1 || runner.sends[0] != "from file" {
		t.Fatalf("send payloads = %#v, want file body", runner.sends)
	}
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
// report command tests
// ---------------------------------------------------------------------------

func TestReportCmd_Success(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-master", "master", "/tmp", "master")
	createWorkerManifest(t, store, "qm-w1", "qm-master")

	out := runCmd(t, store, messagingRunner("qm-master"), "report", "qm-w1", "done: fixed it")
	var got struct {
		SessionID string `json:"session_id"`
		Reported  bool   `json:"reported"`
	}
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("report output is not JSON: %v\n%s", err, out)
	}
	if got.SessionID != "qm-w1" || !got.Reported {
		t.Fatalf("report JSON mismatch: %#v", got)
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

func TestReportCmd_ReadsMessageFileFromStdin(t *testing.T) {
	store := setupStore(t)
	createManifest(t, store, "qm-master", "master", "/tmp", "master")
	createWorkerManifest(t, store, "qm-w1", "qm-master")
	runner := newSendCaptureRunner("qm-master")

	out := runCmdInput(t, store, runner, strings.NewReader("done from stdin"), "report", "qm-w1", "--message-file", "-")
	var got struct {
		SessionID string `json:"session_id"`
		Reported  bool   `json:"reported"`
	}
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("report output is not JSON: %v\n%s", err, out)
	}
	if got.SessionID != "qm-w1" || !got.Reported {
		t.Fatalf("report JSON mismatch: %#v", got)
	}
	if len(runner.sends) != 1 || runner.sends[0] != "[WORKER:qm-w1] done from stdin" {
		t.Fatalf("send payloads = %#v, want report body", runner.sends)
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
