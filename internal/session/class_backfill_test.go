//go:build linux || darwin

package session

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
)

type classBackfillRunner struct {
	sessions string
	err      error
	calls    int
}

func (r *classBackfillRunner) Run(_ context.Context, _ ...string) (string, error) {
	r.calls++
	return r.sessions, r.err
}

func TestClassBackfillJobBalancesLiveMastersAndStopsAfterSuccess(t *testing.T) {
	store, err := state.NewStore(t.TempDir())
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	classes := []string{"paladin", "wizard", "druid", "barbarian", "rogue", "cleric"}
	liveIDs := make([]string, 0, len(classes)+4)
	classedManifestBytes := make(map[string][]byte, len(classes))
	for _, class := range classes {
		id := "qm-master-" + class
		createClassBackfillMaster(t, store, id, class)
		liveIDs = append(liveIDs, id)
		classedManifestBytes[id] = readClassBackfillManifestBytes(t, store, id)
	}

	createClassBackfillMaster(t, store, "qm-live-missing", "")
	createClassBackfillMaster(t, store, "qm-stopped-old", "")
	oldUpdatedAt, oldModTime := ageClassBackfillManifest(t, store, "qm-stopped-old")
	liveIDs = append(liveIDs, "qm-live-missing")

	worker := state.Manifest{
		SessionID: "qm-worker",
		Agents:    []state.AgentManifest{{Name: "codex", Role: "primary"}},
		Display:   &state.DisplayMetadata{Class: "bard"},
		Extra:     map[string]json.RawMessage{"parent_session": json.RawMessage(`"qm-master-paladin"`)},
	}
	if err := store.Create(worker); err != nil {
		t.Fatalf("create worker: %v", err)
	}
	shell := state.Manifest{SessionID: "qm-shell", Display: &state.DisplayMetadata{Class: "bard"}}
	if err := store.Create(shell); err != nil {
		t.Fatalf("create shell: %v", err)
	}
	workerBytes := readClassBackfillManifestBytes(t, store, worker.SessionID)
	shellBytes := readClassBackfillManifestBytes(t, store, shell.SessionID)
	liveIDs = append(liveIDs, worker.SessionID, shell.SessionID)

	runner := &classBackfillRunner{sessions: strings.Join(liveIDs, "\n")}
	job := NewClassBackfillJob(store, tmux.NewClient(runner))
	job.randomIndex = func(int) int { return 0 }
	if !job.HasWork() {
		t.Fatal("HasWork() = false before classless masters are backfilled")
	}

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- job.Run(ctx) }()
	deadline := time.NewTimer(3 * time.Second)
	ticker := time.NewTicker(time.Millisecond)
	defer deadline.Stop()
	defer ticker.Stop()
	for job.HasWork() {
		select {
		case err := <-done:
			cancel()
			t.Fatalf("Run returned before cancellation: %v", err)
		case <-deadline.C:
			cancel()
			t.Fatal("class backfill did not finish")
		case <-ticker.C:
		}
	}
	select {
	case err := <-done:
		cancel()
		t.Fatalf("Run returned after a complete pass: %v", err)
	default:
	}
	if runner.calls != 1 {
		cancel()
		t.Fatalf("tmux list calls = %d, want one completed pass", runner.calls)
	}
	cancel()
	if err := <-done; err != nil {
		t.Fatalf("Run after cancellation: %v", err)
	}

	for id, want := range map[string]string{
		"qm-live-missing":   "bard",
		"qm-stopped-old":    "paladin",
		"qm-master-paladin": "paladin",
	} {
		manifest, err := store.Read(id)
		if err != nil {
			t.Fatalf("read %s: %v", id, err)
		}
		if manifest.DisplayClass() != want {
			t.Fatalf("%s class = %q, want %q", id, manifest.DisplayClass(), want)
		}
	}
	for id, before := range classedManifestBytes {
		if after := readClassBackfillManifestBytes(t, store, id); string(after) != string(before) {
			t.Fatalf("already-classed manifest %s changed", id)
		}
	}
	if after := readClassBackfillManifestBytes(t, store, worker.SessionID); string(after) != string(workerBytes) {
		t.Fatal("worker manifest changed")
	}
	if after := readClassBackfillManifestBytes(t, store, shell.SessionID); string(after) != string(shellBytes) {
		t.Fatal("shell manifest changed")
	}
	stopped, err := store.Read("qm-stopped-old")
	if err != nil {
		t.Fatalf("read stopped master: %v", err)
	}
	if stopped.UpdatedAt != oldUpdatedAt {
		t.Fatalf("stopped updated_at = %q, want %q", stopped.UpdatedAt, oldUpdatedAt)
	}
	info, err := os.Stat(filepath.Join(store.Root(), "qm-stopped-old.json"))
	if err != nil {
		t.Fatalf("stat stopped master: %v", err)
	}
	if !info.ModTime().Equal(oldModTime) {
		t.Fatalf("stopped mtime = %v, want %v", info.ModTime(), oldModTime)
	}
	if job.HasWork() {
		t.Fatal("HasWork() = true after all master classes were persisted")
	}
}

func TestClassBackfillJobRescansNewMastersWithoutReportingWork(t *testing.T) {
	store, err := state.NewStore(t.TempDir())
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	job := NewClassBackfillJob(store, tmux.NewClient(&classBackfillRunner{sessions: "qm-later"}))
	job.randomIndex = func(int) int { return 0 }
	job.rescanInterval = 200 * time.Millisecond
	if !job.HasWork() {
		t.Fatal("HasWork() = false before the first pass")
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- job.Run(ctx) }()
	deadline := time.NewTimer(3 * time.Second)
	ticker := time.NewTicker(time.Millisecond)
	defer deadline.Stop()
	defer ticker.Stop()
	for job.HasWork() {
		select {
		case err := <-done:
			t.Fatalf("Run returned before cancellation: %v", err)
		case <-deadline.C:
			t.Fatal("first backfill pass did not finish")
		case <-ticker.C:
		}
	}
	if err := store.Create(state.Manifest{
		SessionID: "qm-later",
		Agents:    []state.AgentManifest{{Name: "codex", Role: "primary"}},
	}); err != nil {
		t.Fatalf("create master after first pass: %v", err)
	}
	if job.HasWork() {
		t.Fatal("HasWork() = true between successful passes")
	}
	time.Sleep(20 * time.Millisecond)
	if job.HasWork() {
		t.Fatal("HasWork() = true before the rescan interval")
	}
	for {
		manifest, err := store.Read("qm-later")
		if err != nil {
			t.Fatalf("read later master: %v", err)
		}
		if manifest.DisplayClass() != "" {
			break
		}
		select {
		case err := <-done:
			t.Fatalf("Run returned before cancellation: %v", err)
		case <-deadline.C:
			t.Fatal("rescan did not backfill the later master")
		case <-ticker.C:
		}
	}
	cancel()
	if err := <-done; err != nil {
		t.Fatalf("Run after cancellation: %v", err)
	}
}

func TestClassBackfillJobFailures(t *testing.T) {
	tests := []struct {
		name          string
		runnerError   error
		blockedID     string
		wantClassed   []string
		wantUnclassed []string
	}{
		{
			name:          "tmux error persists nothing",
			runnerError:   &tmux.ExitError{Code: 1, Stderr: "error connecting to /tmp/tmux-1000/default: Permission denied"},
			wantUnclassed: []string{"qm-a", "qm-b"},
		},
		{
			name:          "write failure continues",
			blockedID:     "qm-a",
			wantClassed:   []string{"qm-b", "qm-c"},
			wantUnclassed: []string{"qm-a"},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			store, err := state.NewStore(t.TempDir())
			if err != nil {
				t.Fatalf("new store: %v", err)
			}
			ids := []string{"qm-a", "qm-b"}
			if tt.blockedID != "" {
				ids = append(ids, "qm-c")
			}
			for _, id := range ids {
				createClassBackfillMaster(t, store, id, "")
			}
			if tt.blockedID != "" {
				blockedPath := filepath.Join(store.Root(), tt.blockedID+".json.tmp")
				if err := os.Mkdir(blockedPath, 0o700); err != nil {
					t.Fatalf("block manifest temp path: %v", err)
				}
				defer os.RemoveAll(blockedPath)
			}
			runner := &classBackfillRunner{sessions: strings.Join(ids, "\n"), err: tt.runnerError}
			job := NewClassBackfillJob(store, tmux.NewClient(runner))
			job.randomIndex = func(int) int { return 0 }
			if !job.HasWork() {
				t.Fatal("HasWork() = false before failed pass")
			}
			if err := job.Run(context.Background()); err == nil {
				t.Fatal("Run() error = nil, want failed pass error")
			}
			for _, id := range tt.wantClassed {
				manifest, err := store.Read(id)
				if err != nil {
					t.Fatalf("read %s: %v", id, err)
				}
				if manifest.DisplayClass() == "" {
					t.Errorf("%s remains classless after pass", id)
				}
			}
			for _, id := range tt.wantUnclassed {
				manifest, err := store.Read(id)
				if err != nil {
					t.Fatalf("read %s: %v", id, err)
				}
				if manifest.DisplayClass() != "" {
					t.Errorf("%s class = %q after failed pass, want none", id, manifest.DisplayClass())
				}
			}
			if tt.runnerError != nil && runner.calls != 1 {
				t.Fatalf("tmux list calls = %d, want 1", runner.calls)
			}
			if tt.blockedID != "" && runner.calls != 1 {
				t.Fatalf("tmux list calls = %d, want pass to continue after write failure", runner.calls)
			}
			if !job.HasWork() {
				t.Fatal("HasWork() = false while a failed master remains classless")
			}
		})
	}
}

func createClassBackfillMaster(t *testing.T, store *state.Store, id, class string) {
	t.Helper()
	manifest := state.Manifest{
		SessionID: id,
		Agents:    []state.AgentManifest{{Name: "codex", Role: "primary"}},
	}
	if class != "" {
		manifest.Display = &state.DisplayMetadata{Class: class}
	}
	if err := store.Create(manifest); err != nil {
		t.Fatalf("create master %s: %v", id, err)
	}
}

func readClassBackfillManifestBytes(t *testing.T, store *state.Store, id string) []byte {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join(store.Root(), id+".json"))
	if err != nil {
		t.Fatalf("read manifest bytes %s: %v", id, err)
	}
	return raw
}

func ageClassBackfillManifest(t *testing.T, store *state.Store, id string) (string, time.Time) {
	t.Helper()
	manifest, err := store.Read(id)
	if err != nil {
		t.Fatalf("read manifest %s: %v", id, err)
	}
	manifest.UpdatedAt = "2020-01-02T03:04:05Z"
	raw, err := json.Marshal(manifest)
	if err != nil {
		t.Fatalf("marshal manifest %s: %v", id, err)
	}
	path := filepath.Join(store.Root(), id+".json")
	if err := os.WriteFile(path, raw, 0o644); err != nil {
		t.Fatalf("write manifest %s: %v", id, err)
	}
	old := time.Date(2020, 1, 2, 3, 4, 5, 0, time.UTC)
	if err := os.Chtimes(path, old, old); err != nil {
		t.Fatalf("age manifest %s: %v", id, err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat manifest %s: %v", id, err)
	}
	return manifest.UpdatedAt, info.ModTime()
}
