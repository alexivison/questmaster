//go:build linux || darwin

package tui

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"testing"

	"github.com/anthropics/ai-party/tools/party-cli/internal/message"
	"github.com/anthropics/ai-party/tools/party-cli/internal/session"
	"github.com/anthropics/ai-party/tools/party-cli/internal/state"
	"github.com/anthropics/ai-party/tools/party-cli/internal/tmux"
)

// ---------------------------------------------------------------------------
// Mock tmux runner
// ---------------------------------------------------------------------------

type mockRunner struct {
	fn func(ctx context.Context, args ...string) (string, error)
}

func (m *mockRunner) Run(ctx context.Context, args ...string) (string, error) {
	return m.fn(ctx, args...)
}

// allDeadRunner returns a runner where all sessions are dead.
func allDeadRunner() *mockRunner {
	return &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) >= 1 && args[0] == "kill-session" {
			return "", nil // KillSession is lenient for dead sessions
		}
		return "", &tmux.ExitError{Code: 1}
	}}
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

func setupTrackerTest(t *testing.T) (*state.Store, *tmux.Client, *session.Service, *message.Service) {
	t.Helper()
	store, err := state.NewStore(t.TempDir())
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	runner := allDeadRunner()
	client := tmux.NewClient(runner)
	sessionSvc := session.NewService(store, client, t.TempDir())
	messageSvc := message.NewService(store, client)
	return store, client, sessionSvc, messageSvc
}

// ---------------------------------------------------------------------------
// Ghost worker tests — Stop and Delete with missing manifest
// ---------------------------------------------------------------------------

func TestStop_GhostWorkerNoManifest(t *testing.T) {
	t.Parallel()
	store, client, sessionSvc, messageSvc := setupTrackerTest(t)

	// Create master with a ghost worker (in Workers list, no manifest, no tmux)
	m := state.Manifest{
		PartyID:     "party-master",
		Cwd:         "/tmp",
		SessionType: "master",
	}
	if err := store.Create(m); err != nil {
		t.Fatalf("create master: %v", err)
	}
	if err := store.AddWorker("party-master", "party-ghost"); err != nil {
		t.Fatalf("add ghost: %v", err)
	}

	actions := NewLiveTrackerActions(sessionSvc, messageSvc, client, store)

	// Stop the ghost worker — this should remove it from master's Workers list
	if err := actions.Stop(t.Context(), "party-master", "party-ghost"); err != nil {
		t.Fatalf("stop ghost: %v", err)
	}

	workers, err := store.GetWorkers("party-master")
	if err != nil {
		t.Fatalf("get workers: %v", err)
	}
	for _, id := range workers {
		if id == "party-ghost" {
			t.Fatal("ghost worker should have been removed from master's Workers list after Stop")
		}
	}
}

func TestStop_WithManifest_NoDoubleDeregister(t *testing.T) {
	t.Parallel()
	store, _, sessionSvc, messageSvc := setupTrackerTest(t)

	// Create master and worker with proper manifests.
	masterM := state.Manifest{
		PartyID:     "party-master",
		Cwd:         "/tmp",
		SessionType: "master",
	}
	if err := store.Create(masterM); err != nil {
		t.Fatalf("create master: %v", err)
	}
	workerM := state.Manifest{
		PartyID: "party-w1",
		Cwd:     "/tmp",
		Extra: map[string]json.RawMessage{
			"parent_session": json.RawMessage(`"party-master"`),
		},
	}
	if err := store.Create(workerM); err != nil {
		t.Fatalf("create worker: %v", err)
	}
	if err := store.AddWorker("party-master", "party-w1"); err != nil {
		t.Fatalf("add worker: %v", err)
	}

	// Runner where run-shell succeeds (session is alive).
	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) >= 1 && args[0] == "kill-session" {
			return "", nil
		}
		if len(args) >= 1 && args[0] == "run-shell" {
			return "", nil
		}
		return "", &tmux.ExitError{Code: 1}
	}}
	client := tmux.NewClient(runner)
	actions := NewLiveTrackerActions(sessionSvc, messageSvc, client, store)

	if err := actions.Stop(t.Context(), "party-master", "party-w1"); err != nil {
		t.Fatalf("stop: %v", err)
	}

	// Worker should be removed from master's list (via Deregister).
	workers, err := store.GetWorkers("party-master")
	if err != nil {
		t.Fatalf("get workers: %v", err)
	}
	for _, id := range workers {
		if id == "party-w1" {
			t.Fatal("worker should have been removed from master's Workers list after Stop")
		}
	}

	// Worker manifest should be deleted (via Deregister).
	if _, err := store.Read("party-w1"); err == nil {
		t.Fatal("worker manifest should have been deleted after Stop")
	}
}

func TestStop_DeregisterErrorPropagates(t *testing.T) {
	t.Parallel()

	storeDir := t.TempDir()
	store, err := state.NewStore(storeDir)
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		// RunShell succeeds (triggers Deregister path, not Stop fallback).
		if len(args) >= 1 && args[0] == "run-shell" {
			return "", nil
		}
		return "", &tmux.ExitError{Code: 1}
	}}
	client := tmux.NewClient(runner)
	sessionSvc := session.NewService(store, client, t.TempDir())
	messageSvc := message.NewService(store, client)

	// Create master and worker manifests.
	master := state.Manifest{PartyID: "party-master", Cwd: "/tmp", SessionType: "master"}
	if err := store.Create(master); err != nil {
		t.Fatalf("create master: %v", err)
	}
	workerManifest := state.Manifest{PartyID: "party-w1", Cwd: "/tmp"}
	workerManifest.SetExtra("parent_session", "party-master")
	if err := store.Create(workerManifest); err != nil {
		t.Fatalf("create worker: %v", err)
	}
	if err := store.AddWorker("party-master", "party-w1"); err != nil {
		t.Fatalf("add worker: %v", err)
	}

	// Corrupt the manifest path so Store.Delete fails with a real error.
	manifestPath := storeDir + "/party-w1.json"
	os.Remove(manifestPath)
	if err := os.MkdirAll(manifestPath+"/blocker", 0o755); err != nil {
		t.Fatalf("create blocker: %v", err)
	}

	actions := NewLiveTrackerActions(sessionSvc, messageSvc, client, store)

	err = actions.Stop(t.Context(), "party-master", "party-w1")
	if err == nil {
		t.Error("expected error from Deregister failure to propagate through Stop")
	}
}

// ---------------------------------------------------------------------------
// WorkerFetcher resolves claude_session_id from manifest for evidence lookup
// ---------------------------------------------------------------------------

func TestLiveWorkerFetcher_ResolvesClaudeSessionID(t *testing.T) {
	t.Parallel()

	// Need alive runner so Workers() reports status "active" (stage is only set for active workers).
	store, _, _, _ := setupTrackerTest(t)
	aliveRunner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) >= 1 && args[0] == "has-session" {
			return "", nil
		}
		return "", &tmux.ExitError{Code: 1}
	}}
	client := tmux.NewClient(aliveRunner)
	messageSvc := message.NewService(store, client)

	masterID := "party-master"
	workerID := "party-worker1"
	claudeUUID := "632ed9c0-23d4-4573-8787-069453e360a5"

	// Create master manifest with worker reference.
	masterM := state.Manifest{
		PartyID:     masterID,
		Cwd:         "/tmp",
		SessionType: "master",
	}
	if err := store.Create(masterM); err != nil {
		t.Fatalf("create master: %v", err)
	}
	if err := store.AddWorker(masterID, workerID); err != nil {
		t.Fatalf("add worker: %v", err)
	}

	// Create worker manifest with claude_session_id in extras.
	workerM := state.Manifest{
		PartyID: workerID,
		Cwd:     "/tmp",
		Extra: map[string]json.RawMessage{
			"parent_session":    json.RawMessage(`"` + masterID + `"`),
			"claude_session_id": json.RawMessage(`"` + claudeUUID + `"`),
		},
	}
	if err := store.Create(workerM); err != nil {
		t.Fatalf("create worker: %v", err)
	}

	// Write evidence keyed by the Claude UUID (not the tmux session name).
	writeEvidence(t, claudeUUID, []string{
		`{"timestamp":"T","type":"test-runner","result":"PASSED","diff_hash":"aaa"}`,
		`{"timestamp":"T","type":"code-critic","result":"APPROVED","diff_hash":"aaa"}`,
		`{"timestamp":"T","type":"minimizer","result":"APPROVED","diff_hash":"aaa"}`,
	})

	// The fetcher should resolve claude_session_id and find the evidence → StageCriticsOK.
	// Without the fix, it uses the tmux session name → no evidence → StageActive.
	fetcher := NewLiveWorkerFetcher(messageSvc, client, store)
	rows := fetcher(masterID)

	if len(rows) == 0 {
		t.Fatal("expected at least one worker row")
	}

	var found bool
	for _, row := range rows {
		if row.ID == workerID {
			found = true
			if row.Stage != StageCriticsOK {
				t.Errorf("Stage: got %q, want %q (fetcher should resolve claude_session_id from manifest)", row.Stage, StageCriticsOK)
			}
			break
		}
	}
	if !found {
		t.Errorf("worker %s not found in rows", workerID)
	}
}

func TestLiveWorkerFetcher_FallsBackToSessionID(t *testing.T) {
	t.Parallel()

	store, _, _, _ := setupTrackerTest(t)
	aliveRunner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) >= 1 && args[0] == "has-session" {
			return "", nil
		}
		return "", &tmux.ExitError{Code: 1}
	}}
	client := tmux.NewClient(aliveRunner)
	messageSvc := message.NewService(store, client)

	masterID := "party-master"
	workerID := "party-worker2"

	masterM := state.Manifest{
		PartyID:     masterID,
		Cwd:         "/tmp",
		SessionType: "master",
	}
	if err := store.Create(masterM); err != nil {
		t.Fatalf("create master: %v", err)
	}
	if err := store.AddWorker(masterID, workerID); err != nil {
		t.Fatalf("add worker: %v", err)
	}

	// Worker manifest WITHOUT claude_session_id.
	workerM := state.Manifest{
		PartyID: workerID,
		Cwd:     "/tmp",
		Extra: map[string]json.RawMessage{
			"parent_session": json.RawMessage(`"` + masterID + `"`),
		},
	}
	if err := store.Create(workerM); err != nil {
		t.Fatalf("create worker: %v", err)
	}

	// Write evidence keyed by the tmux session name (fallback path).
	writeEvidence(t, workerID, []string{
		`{"timestamp":"T","type":"test-runner","result":"PASSED","diff_hash":"bbb"}`,
	})

	fetcher := NewLiveWorkerFetcher(messageSvc, client, store)
	rows := fetcher(masterID)

	for _, row := range rows {
		if row.ID == workerID {
			if row.Stage != StageTesting {
				t.Errorf("Stage: got %q, want %q (should fall back to session ID)", row.Stage, StageTesting)
			}
			return
		}
	}
	t.Errorf("worker %s not found in rows", workerID)
}

// ---------------------------------------------------------------------------
// ClaudeState reading from claude-state.json
// ---------------------------------------------------------------------------

func TestLiveWorkerFetcher_ReadsClaudeState(t *testing.T) {
	t.Parallel()

	store, _, _, _ := setupTrackerTest(t)
	aliveRunner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) >= 1 && args[0] == "has-session" {
			return "", nil
		}
		return "", &tmux.ExitError{Code: 1}
	}}
	client := tmux.NewClient(aliveRunner)
	messageSvc := message.NewService(store, client)

	masterID := "party-master"
	workerID := "party-cs-test"

	masterM := state.Manifest{
		PartyID:     masterID,
		Cwd:         "/tmp",
		SessionType: "master",
	}
	if err := store.Create(masterM); err != nil {
		t.Fatalf("create master: %v", err)
	}
	if err := store.AddWorker(masterID, workerID); err != nil {
		t.Fatalf("add worker: %v", err)
	}
	workerM := state.Manifest{
		PartyID: workerID,
		Cwd:     "/tmp",
		Extra: map[string]json.RawMessage{
			"parent_session": json.RawMessage(`"` + masterID + `"`),
		},
	}
	if err := store.Create(workerM); err != nil {
		t.Fatalf("create worker: %v", err)
	}

	// Write claude-state.json to the worker's runtime dir
	runtimeDir := fmt.Sprintf("/tmp/%s", workerID)
	if err := os.MkdirAll(runtimeDir, 0o755); err != nil {
		t.Fatalf("mkdir runtime: %v", err)
	}
	stateJSON := `{"state":"waiting","updated_at":"2026-04-12T10:00:00Z"}`
	if err := os.WriteFile(runtimeDir+"/claude-state.json", []byte(stateJSON), 0o644); err != nil {
		t.Fatalf("write claude-state.json: %v", err)
	}
	t.Cleanup(func() {
		os.Remove(runtimeDir + "/claude-state.json")
		os.Remove(runtimeDir)
	})

	fetcher := NewLiveWorkerFetcher(messageSvc, client, store)
	rows := fetcher(masterID)

	var found bool
	for _, row := range rows {
		if row.ID == workerID {
			found = true
			if row.ClaudeState != "waiting" {
				t.Errorf("ClaudeState: got %q, want %q", row.ClaudeState, "waiting")
			}
			break
		}
	}
	if !found {
		t.Errorf("worker %s not found in rows", workerID)
	}
}

func TestLiveWorkerFetcher_ClaudeStateMissing(t *testing.T) {
	t.Parallel()

	store, _, _, _ := setupTrackerTest(t)
	aliveRunner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) >= 1 && args[0] == "has-session" {
			return "", nil
		}
		return "", &tmux.ExitError{Code: 1}
	}}
	client := tmux.NewClient(aliveRunner)
	messageSvc := message.NewService(store, client)

	masterID := "party-master"
	workerID := "party-cs-miss"

	masterM := state.Manifest{
		PartyID:     masterID,
		Cwd:         "/tmp",
		SessionType: "master",
	}
	if err := store.Create(masterM); err != nil {
		t.Fatalf("create master: %v", err)
	}
	if err := store.AddWorker(masterID, workerID); err != nil {
		t.Fatalf("add worker: %v", err)
	}
	workerM := state.Manifest{
		PartyID: workerID,
		Cwd:     "/tmp",
		Extra: map[string]json.RawMessage{
			"parent_session": json.RawMessage(`"` + masterID + `"`),
		},
	}
	if err := store.Create(workerM); err != nil {
		t.Fatalf("create worker: %v", err)
	}

	// No claude-state.json — ClaudeState should be empty
	fetcher := NewLiveWorkerFetcher(messageSvc, client, store)
	rows := fetcher(masterID)

	for _, row := range rows {
		if row.ID == workerID {
			if row.ClaudeState != "" {
				t.Errorf("ClaudeState: got %q, want empty", row.ClaudeState)
			}
			return
		}
	}
	t.Errorf("worker %s not found in rows", workerID)
}

// ---------------------------------------------------------------------------
// Ghost worker tests
// ---------------------------------------------------------------------------

func TestDelete_GhostWorkerNoManifest(t *testing.T) {
	t.Parallel()
	store, client, sessionSvc, messageSvc := setupTrackerTest(t)

	m := state.Manifest{
		PartyID:     "party-master",
		Cwd:         "/tmp",
		SessionType: "master",
	}
	if err := store.Create(m); err != nil {
		t.Fatalf("create master: %v", err)
	}
	if err := store.AddWorker("party-master", "party-ghost"); err != nil {
		t.Fatalf("add ghost: %v", err)
	}

	actions := NewLiveTrackerActions(sessionSvc, messageSvc, client, store)

	// Delete the ghost worker — should remove from master's Workers list
	if err := actions.Delete(t.Context(), "party-master", "party-ghost"); err != nil {
		t.Fatalf("delete ghost: %v", err)
	}

	workers, err := store.GetWorkers("party-master")
	if err != nil {
		t.Fatalf("get workers: %v", err)
	}
	for _, id := range workers {
		if id == "party-ghost" {
			t.Fatal("ghost worker should have been removed from master's Workers list after Delete")
		}
	}
}
