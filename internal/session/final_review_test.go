package session

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmuxroute"
)

func TestDeleteOrphanRequiresCompleteInventory(t *testing.T) {
	// These lifecycle tests set the process-wide state root for cleanup.
	for _, tc := range []struct {
		name, record, wantError string
		cascade                 bool
	}{
		{name: "unreadable registry", record: "{", wantError: "parse tmux server labels"},
		{name: "unreadable registry stops cascade", record: "{", wantError: "parse tmux server labels", cascade: true},
		{name: "label recorded later", record: "late", wantError: "dev_later"},
		{name: "known server"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			svc, legacy, named := routedService(t)
			t.Setenv("QUESTMASTER_STATE_ROOT", svc.Store.Root())
			id, target := "qm-orphan", "qm-orphan"
			named.sessions[id] = true
			if tc.record != "" {
				// A previous development server is hidden from this router.
				svc.Router = tmuxroute.New(svc.Store, map[string]*tmux.Client{"default": tmux.NewClient(legacy)}, func() string { return "default" }, nil)
				if tc.record == "late" {
					if err := state.RecordTmuxServerLabel(svc.Store.Root(), "dev_later"); err != nil {
						t.Fatal(err)
					}
				} else if err := os.WriteFile(filepath.Join(svc.Store.Root(), "tmux-servers.json"), []byte(tc.record), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			if tc.cascade {
				target = "qm-master"
				createTestManifest(t, svc.Store, target, "master", t.TempDir(), "master")
				if err := svc.Store.AddWorker(target, id); err != nil {
					t.Fatal(err)
				}
				legacy.sessions[target] = true
			}
			marker := filepath.Join(state.SessionStateDir(svc.Store.Root(), id), "state.json")
			if err := os.MkdirAll(filepath.Dir(marker), 0o700); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(marker, []byte("{}"), 0o600); err != nil {
				t.Fatal(err)
			}
			ref, err := state.ParsePullRequestRef("example/example-app#1")
			if err != nil {
				t.Fatal(err)
			}
			createTestManifest(t, svc.Store, id, "orphan", t.TempDir(), "")
			if _, err := state.WatchPullRequest(svc.Store.Root(), id, ref, time.Now()); err != nil {
				t.Fatal(err)
			}
			if err := svc.Store.Delete(id); err != nil {
				t.Fatal(err)
			}
			watchesBefore, err := os.ReadFile(filepath.Join(svc.Store.Root(), "pull_requests.json"))
			if err != nil {
				t.Fatal(err)
			}
			dropped, err := svc.Delete(t.Context(), target)
			if tc.wantError == "" {
				if err != nil || dropped != 1 || named.sessions[id] {
					t.Fatalf("Delete = %d, %v; orphan live = %v", dropped, err, named.sessions[id])
				}
				if _, err := os.Stat(marker); !errors.Is(err, os.ErrNotExist) {
					t.Fatalf("state remains: %v", err)
				}
				return
			}
			if err == nil || !strings.Contains(err.Error(), tc.wantError) || dropped != 0 {
				t.Errorf("Delete = %d, %v; want error containing %q", dropped, err, tc.wantError)
			}
			if !named.sessions[id] || len(callsAfter(legacy, 0, "kill-session")) != 0 || len(callsAfter(named, 0, "kill-session")) != 0 {
				t.Error("session changed with incomplete inventory")
			}
			if _, err := os.Stat(marker); err != nil {
				t.Errorf("state removed: %v", err)
			}
			watchesAfter, err := os.ReadFile(filepath.Join(svc.Store.Root(), "pull_requests.json"))
			if err != nil || string(watchesAfter) != string(watchesBefore) {
				t.Errorf("watches changed: %v", err)
			}
			if tc.cascade {
				m, err := svc.Store.Read(target)
				if err != nil || len(m.Workers) != 1 || m.Workers[0] != id || !legacy.sessions[target] {
					t.Errorf("master changed: %+v, %v", m, err)
				}
			}
		})
	}
}

func TestStartRouteWriteFailureRollback(t *testing.T) {
	for _, killFails := range []bool{false, true} {
		name := "kill succeeds"
		if killFails {
			name = "kill fails"
		}
		t.Run(name, func(t *testing.T) {
			svc, _, named := routedService(t)
			t.Setenv("QUESTMASTER_STATE_ROOT", svc.Store.Root())
			svc.Now = func() int64 { return 301 }
			id := "qm-301"
			blocker := filepath.Join(svc.Store.Root(), id+".json.tmp")
			named.fn = func(ctx context.Context, args ...string) (string, error) {
				if args[0] == "kill-session" {
					if err := os.Remove(blocker); err != nil {
						t.Fatal(err)
					}
					if killFails {
						return "", errors.New("temporary transport failure")
					}
				}
				out, err := named.defaultHandler(ctx, args...)
				if args[0] == "new-session" && err == nil {
					if err := os.Mkdir(blocker, 0o700); err != nil {
						t.Fatal(err)
					}
				}
				return out, err
			}
			_, startErr := svc.Start(t.Context(), StartOpts{Shell: true, Cwd: t.TempDir()})
			if startErr == nil || !strings.Contains(startErr.Error(), "record tmux server: write temp manifest") {
				t.Fatalf("Start error = %v", startErr)
			}
			m, err := svc.Store.Read(id)
			if !killFails {
				if !errors.Is(err, os.ErrNotExist) || named.sessions[id] {
					t.Fatalf("partial start remains: live=%v, manifest error=%v", named.sessions[id], err)
				}
				return
			}
			if !strings.Contains(startErr.Error(), "temporary transport failure") {
				t.Errorf("rollback error missing: %v", startErr)
			}
			if err != nil || !named.sessions[id] || m.TmuxServer != "test_named" {
				t.Fatalf("surviving container route = %q, live=%v, read error=%v", m.TmuxServer, named.sessions[id], err)
			}
			if _, err := os.Stat(state.NewRuntimeDir(svc.Store.Root(), id)); err != nil {
				t.Fatalf("live container runtime removed: %v", err)
			}
		})
	}
}
