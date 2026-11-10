//go:build linux || darwin

package session_test

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/serve"
	"github.com/alexivison/questmaster/internal/session"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmuxroute"
)

type closingWorkerRunner struct{ alive bool }

func (r *closingWorkerRunner) Run(_ context.Context, args ...string) (string, error) {
	switch args[0] {
	case "list-sessions":
		if r.alive {
			return "qm-worker", nil
		}
		return "", nil
	case "has-session":
		if r.alive {
			return "", nil
		}
		return "", &tmux.ExitError{Code: 1}
	default:
		return "", fmt.Errorf("unexpected tmux call: %v", args)
	}
}

func TestSessionClosedRefreshesTrackerLiveness(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	root := t.TempDir()
	t.Setenv("QUESTMASTER_STATE_ROOT", root)
	store, err := state.NewStore(root)
	if err != nil {
		t.Fatal(err)
	}
	id := "qm-worker"
	m := state.Manifest{SessionID: id, TmuxServer: "test_named", Cwd: t.TempDir(), RuntimeDir: state.NewRuntimeDir(root, id)}
	m.Agents = []state.AgentManifest{{Name: "claude", Role: "agent", ResumeID: "saved-conversation"}}
	m.Workers = []string{"qm-descendant"}
	m.SetExtra("parent_session", "qm-master")
	m.SetExtra("claude_session_id", "saved-conversation")
	if err := store.Create(m); err != nil {
		t.Fatal(err)
	}
	if err := state.EnsureRuntimeDir(m.RuntimeDir); err != nil {
		t.Fatal(err)
	}
	beforeManifest, err := store.Read(id)
	if err != nil {
		t.Fatal(err)
	}
	manifestPath := filepath.Join(root, id+".json")
	beforeFile, err := os.Stat(manifestPath)
	if err != nil {
		t.Fatal(err)
	}
	runner := &closingWorkerRunner{alive: true}
	client := tmux.NewClient(runner)
	router := tmuxroute.New(store, map[string]*tmux.Client{"test_named": client}, func() string { return "test_named" }, nil)
	svc := session.NewService(store, client, "")
	svc.Router = router
	snapshotter := serve.NewSnapshotter(store, client, nil, router)
	before, err := snapshotter.TrackerForChange(serve.Change{})
	if err != nil || len(before.Sessions) != 1 || before.Sessions[0].Status != "active" {
		t.Fatalf("initial tracker = %+v, %v", before, err)
	}
	source, err := serve.NewFileChangeSource(t.Context(), snapshotter, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer source.Close()
	changes, unsubscribe := source.Subscribe(t.Context())
	defer unsubscribe()
	runner.alive = false
	if err := svc.SessionClosed(t.Context(), "test_named", id); err != nil {
		t.Fatal(err)
	}
	afterManifest, err := store.Read(id)
	if err != nil {
		t.Fatal(err)
	}
	afterManifest.UpdatedAt = beforeManifest.UpdatedAt
	if !reflect.DeepEqual(afterManifest, beforeManifest) {
		t.Fatalf("close changed manifest fields: before %+v, after %+v", beforeManifest, afterManifest)
	}
	afterFile, err := os.Stat(manifestPath)
	if err != nil || afterFile.Mode() != beforeFile.Mode() {
		t.Fatalf("manifest mode changed: %v, %v", afterFile, err)
	}
	select {
	case change := <-changes:
		if !change.Lifecycle || !slices.Contains(change.SessionIDs, id) {
			t.Fatalf("close change = %+v", change)
		}
		snapshotter.Invalidate(change)
		after, err := snapshotter.TrackerForChange(change)
		if err != nil || len(after.Sessions) != 1 || after.Sessions[0].Status != "stopped" || after.Sessions[0].State != "stopped" {
			t.Fatalf("tracker after close = %+v, %v", after, err)
		}
	case <-time.After(2 * time.Second):
		cached, err := snapshotter.TrackerForChange(serve.Change{Clock: true})
		t.Fatalf("close produced no tracker lifecycle change; cached tracker = %+v, %v", cached, err)
	}
}
