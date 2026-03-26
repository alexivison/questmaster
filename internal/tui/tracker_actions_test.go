//go:build linux || darwin

package tui

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/anthropics/ai-config/tools/party-cli/internal/message"
	"github.com/anthropics/ai-config/tools/party-cli/internal/session"
	"github.com/anthropics/ai-config/tools/party-cli/internal/state"
	"github.com/anthropics/ai-config/tools/party-cli/internal/tmux"
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
