//go:build linux || darwin

package session

import (
	"errors"
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/message"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tracker"
	"github.com/alexivison/questmaster/internal/workerfeed"
)

func TestContinueMasterAfterSessionClosed(t *testing.T) {
	for _, tc := range []struct {
		name       string
		closeOrder []string
		deleted    bool
		fail       bool
		wantRevive bool
	}{
		{name: "worker first", closeOrder: []string{"qm-worker", "qm-master"}, wantRevive: true},
		{name: "master first", closeOrder: []string{"qm-master", "qm-worker"}, wantRevive: true},
		{name: "master stays live", closeOrder: []string{"qm-worker"}, wantRevive: true},
		{name: "deleted worker", closeOrder: []string{"qm-worker", "qm-master"}, deleted: true},
		{name: "worker continue fails", closeOrder: []string{"qm-worker", "qm-master"}, fail: true},
		{name: "worker stays live", closeOrder: []string{"qm-master"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("HOME", t.TempDir())
			svc, _, named := routedService(t)
			t.Setenv("QUESTMASTER_STATE_ROOT", svc.Store.Root())
			master, worker := "qm-master", "qm-worker"
			for _, id := range []string{master, worker} {
				createTestManifest(t, svc.Store, id, id, t.TempDir(), "")
				if err := svc.Store.Update(id, func(m *state.Manifest) {
					m.TmuxServer = "test_named"
					if id == master {
						m.SessionType = "master"
					} else {
						m.SetExtra("parent_session", master)
					}
				}); err != nil {
					t.Fatal(err)
				}
				named.sessions[id] = true
			}
			if err := svc.Store.AddWorker(master, worker); err != nil {
				t.Fatal(err)
			}
			for _, id := range tc.closeOrder {
				if err := tmux.NewClient(named).KillSession(t.Context(), id); err != nil {
					t.Fatal(err)
				}
				if err := svc.SessionClosed(t.Context(), "test_named", id); err != nil {
					t.Fatal(err)
				}
			}
			if tc.deleted {
				if _, err := svc.Delete(t.Context(), worker); err != nil {
					t.Fatal(err)
				}
				if _, err := svc.Store.Read(worker); !errors.Is(err, os.ErrNotExist) {
					t.Fatalf("deleted worker manifest: %v", err)
				}
			}
			if tc.fail {
				if err := svc.Store.Update(worker, func(m *state.Manifest) {
					m.Cwd = filepath.Join(t.TempDir(), "missing")
				}); err != nil {
					t.Fatal(err)
				}
			}
			before := len(named.calls)
			result, err := svc.Continue(t.Context(), master)
			if err != nil {
				t.Fatal(err)
			}
			var revived, failed []string
			if tc.wantRevive {
				revived = []string{worker}
			}
			if tc.fail {
				failed = []string{worker}
			}
			if !result.Master || !slices.Equal(result.RevivedWorkers, revived) || !slices.Equal(result.FailedWorkers, failed) {
				workers, _ := svc.Store.GetWorkers(master)
				t.Fatalf("Continue = %+v, want revived %v, failed %v; registered workers = %v", result, revived, failed, workers)
			}
			if got := named.sessions[worker]; got != (!tc.deleted && !tc.fail) {
				t.Fatalf("worker alive = %v", got)
			}
			if tc.name == "worker stays live" {
				for _, call := range callsAfter(named, before, "new-session") {
					if flagVal(call, "-s") == worker {
						t.Fatal("live worker was recreated")
					}
				}
			}
		})
	}
}

func TestSessionClosedWorkerRemainsVisible(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	svc, _, named := routedService(t)
	t.Setenv("QUESTMASTER_STATE_ROOT", svc.Store.Root())
	master, worker := "qm-master", "qm-worker"
	createTestManifest(t, svc.Store, master, "Master", t.TempDir(), "master")
	createTestManifest(t, svc.Store, worker, "Worker", t.TempDir(), "")
	if err := svc.Store.Update(worker, func(m *state.Manifest) {
		m.TmuxServer = "test_named"
		m.SetExtra("parent_session", master)
	}); err != nil {
		t.Fatal(err)
	}
	if err := svc.Store.AddWorker(master, worker); err != nil {
		t.Fatal(err)
	}
	if err := workerfeed.RecordChatEntryAt(svc.Store.Root(), worker, "status", "Checkpoint saved", time.Unix(1, 0)); err != nil {
		t.Fatal(err)
	}
	delete(named.sessions, worker)
	if err := svc.SessionClosed(t.Context(), "test_named", worker); err != nil {
		t.Fatal(err)
	}
	workers, err := message.NewServiceWithRouter(svc.Store, svc.Router).Workers(t.Context(), master)
	if err != nil {
		t.Fatal(err)
	}
	if len(workers) != 1 || workers[0].SessionID != worker || workers[0].Title != "Worker" || workers[0].Status != "stopped" {
		t.Errorf("stopped workers = %+v", workers)
	}
	fetch := tracker.NewLiveSessionFetcher(svc.Client, svc.Store, state.NewProjectResolver(), svc.Router)
	snapshot, err := fetch(tracker.SessionInfo{ID: master})
	if err != nil {
		t.Fatal(err)
	}
	if len(snapshot.Sessions) != 2 || snapshot.Sessions[0].ID != master || snapshot.Sessions[0].WorkerCount != 1 || snapshot.Sessions[1].ID != worker || snapshot.Sessions[1].Status != "stopped" || snapshot.Sessions[1].ParentID != master || snapshot.Sessions[1].SessionType != "worker" {
		t.Errorf("tracker rows = %+v", snapshot.Sessions)
	}
	feed, err := workerfeed.ReadSince(svc.Store.Root(), master, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(feed.Errors) != 0 || len(feed.Entries) != 1 || feed.Entries[0].WorkerID != worker || feed.Entries[0].WorkerTitle != "Worker" || feed.Entries[0].Text != "Checkpoint saved" {
		t.Errorf("Worker Log = %+v", feed)
	}
	if err := svc.Store.Delete(worker); err != nil {
		t.Fatal(err)
	}
	workers, err = message.NewServiceWithRouter(svc.Store, svc.Router).Workers(t.Context(), master)
	if err != nil || len(workers) != 0 {
		t.Fatalf("ghost workers = %+v, %v", workers, err)
	}
	remaining, err := svc.Store.GetWorkers(master)
	if err != nil || len(remaining) != 0 {
		t.Fatalf("ghost registration = %v, %v", remaining, err)
	}
}
