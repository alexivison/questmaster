//go:build linux || darwin

package session

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
)

// W2: Delete should propagate manifest deletion errors.
func TestDelete_PropagatesDeleteError(t *testing.T) {
	t.Parallel()

	storeDir := t.TempDir()
	store, err := state.NewStore(storeDir)
	if err != nil {
		t.Fatal(err)
	}

	sessionID := "qm-deltest"

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

func TestDeregisterClearsQuestAttachmentState(t *testing.T) {
	stateRoot := t.TempDir()
	t.Setenv(state.StateRootEnv, stateRoot)
	store, err := state.NewStore(stateRoot)
	if err != nil {
		t.Fatal(err)
	}
	sessionID := "qm-worker"
	if err := store.Create(state.Manifest{SessionID: sessionID}); err != nil {
		t.Fatalf("create manifest: %v", err)
	}
	if err := state.StampQuest(sessionID, "DEMO-1"); err != nil {
		t.Fatalf("stamp quest: %v", err)
	}

	svc := &Service{Store: store, Client: tmux.NewClient(noopKillRunner())}
	if err := svc.Deregister(sessionID); err != nil {
		t.Fatalf("Deregister: %v", err)
	}
	assertNoQuestAttachments(t, "DEMO-1")
	if _, err := os.Stat(state.SessionStateDir(stateRoot, sessionID)); !os.IsNotExist(err) {
		t.Fatalf("session state dir should be removed after deregister, err=%v", err)
	}
}

func TestDeleteCleansWorkerQuestAttachmentState(t *testing.T) {
	stateRoot := t.TempDir()
	t.Setenv(state.StateRootEnv, stateRoot)
	store, err := state.NewStore(stateRoot)
	if err != nil {
		t.Fatal(err)
	}
	masterID := "qm-master"
	workerID := "qm-worker"
	if err := store.Create(state.Manifest{SessionID: masterID, SessionType: "master", Workers: []string{workerID}}); err != nil {
		t.Fatalf("create master manifest: %v", err)
	}
	worker := state.Manifest{SessionID: workerID}
	worker.SetExtra("parent_session", masterID)
	if err := store.Create(worker); err != nil {
		t.Fatalf("create worker manifest: %v", err)
	}
	if err := state.StampQuest(masterID, "DEMO-1"); err != nil {
		t.Fatalf("stamp master quest: %v", err)
	}
	if err := state.StampQuest(workerID, "DEMO-1"); err != nil {
		t.Fatalf("stamp worker quest: %v", err)
	}

	svc := &Service{Store: store, Client: tmux.NewClient(noopKillRunner())}
	if err := svc.Delete(t.Context(), masterID); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	assertNoQuestAttachments(t, "DEMO-1")
	for _, sessionID := range []string{masterID, workerID} {
		if _, err := os.Stat(state.SessionStateDir(stateRoot, sessionID)); !os.IsNotExist(err) {
			t.Fatalf("session state dir %s should be removed after delete, err=%v", sessionID, err)
		}
	}
}

func noopKillRunner() *testRunner {
	return &testRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if args[0] == "kill-session" {
			return "", nil
		}
		return "", nil
	}}
}

func assertNoQuestAttachments(t *testing.T, questID string) {
	t.Helper()
	ids, err := state.SessionsForQuest(questID)
	if err != nil {
		t.Fatalf("SessionsForQuest: %v", err)
	}
	if len(ids) != 0 {
		t.Fatalf("quest %s still has attached sessions: %v", questID, ids)
	}
}
