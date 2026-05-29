//go:build linux || darwin

package tui

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/message"
	"github.com/alexivison/questmaster/internal/session"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
)

type mockRunner struct {
	fn func(ctx context.Context, args ...string) (string, error)
}

func (m *mockRunner) Run(ctx context.Context, args ...string) (string, error) {
	return m.fn(ctx, args...)
}

type recordingRunner struct {
	fn    func(ctx context.Context, args ...string) (string, error)
	calls [][]string
}

func (r *recordingRunner) Run(ctx context.Context, args ...string) (string, error) {
	r.calls = append(r.calls, append([]string(nil), args...))
	return r.fn(ctx, args...)
}

func allDeadRunner() *mockRunner {
	return &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) >= 1 && args[0] == "kill-session" {
			return "", nil
		}
		return "", &tmux.ExitError{Code: 1}
	}}
}

func runnerWithLiveSessions(live map[string]bool) *mockRunner {
	return &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) == 0 {
			return "", &tmux.ExitError{Code: 1}
		}
		switch args[0] {
		case "list-sessions":
			sessions := make([]string, 0, len(live))
			for sessionID, alive := range live {
				if alive {
					sessions = append(sessions, sessionID)
				}
			}
			sort.Strings(sessions)
			return strings.Join(sessions, "\n"), nil
		case "list-panes":
			return "", nil
		case "has-session":
			if len(args) >= 3 && live[args[2]] {
				return "", nil
			}
			return "", &tmux.ExitError{Code: 1}
		default:
			return "", &tmux.ExitError{Code: 1}
		}
	}}
}

func TestLiveSessionFetcherSkipsTmuxCapturePane(t *testing.T) {
	setTestStateRoot(t)

	store, err := state.NewStore(t.TempDir())
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	if err := store.Create(state.Manifest{
		SessionID: "qm-active",
		Agents:    []state.AgentManifest{{Name: "claude", Role: "primary"}},
	}); err != nil {
		t.Fatalf("create active manifest: %v", err)
	}
	if err := store.Create(state.Manifest{SessionID: "qm-stopped"}); err != nil {
		t.Fatalf("create stopped manifest: %v", err)
	}
	writeTrackerStateFixture(t, "qm-active", "working", "Edit foo.go", "PreToolUse", time.Now())

	runner := &recordingRunner{fn: func(_ context.Context, args ...string) (string, error) {
		switch args[0] {
		case "list-sessions":
			return "qm-active", nil
		case "list-panes":
			t.Fatalf("Phase 2 fetcher must not call list-panes")
		case "capture-pane":
			t.Fatalf("Phase 2 fetcher must not call capture-pane")
		}
		return "", &tmux.ExitError{Code: 1}
	}}
	client := tmux.NewClient(runner)

	snapshot, err := NewLiveSessionFetcher(client, store)(SessionInfo{ID: "qm-active"})
	if err != nil {
		t.Fatalf("fetch: %v", err)
	}
	if len(snapshot.Sessions) != 2 {
		t.Fatalf("expected 2 sessions, got %d", len(snapshot.Sessions))
	}

	counts := make(map[string]int)
	for _, call := range runner.calls {
		if len(call) == 0 {
			continue
		}
		counts[call[0]]++
	}
	if counts["has-session"] != 0 {
		t.Fatalf("expected no has-session calls, got %d", counts["has-session"])
	}
	if counts["list-sessions"] != 1 {
		t.Fatalf("list-sessions calls: got %d, want 1", counts["list-sessions"])
	}
	if counts["list-panes"] != 0 {
		t.Fatalf("list-panes calls: got %d, want 0", counts["list-panes"])
	}
	if counts["capture-pane"] != 0 {
		t.Fatalf("capture-pane calls: got %d, want 0", counts["capture-pane"])
	}
}

func TestLiveSessionFetcherInheritsMasterDisplayColorForWorkers(t *testing.T) {
	setTestStateRoot(t)

	store, err := state.NewStore(t.TempDir())
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	if err := store.Create(state.Manifest{
		SessionID:   "qm-master",
		SessionType: "master",
		Workers:     []string{"qm-worker"},
		Display:     &state.DisplayMetadata{Color: "cyan"},
	}); err != nil {
		t.Fatalf("create master manifest: %v", err)
	}
	worker := state.Manifest{SessionID: "qm-worker"}
	worker.SetExtra("parent_session", "qm-master")
	if err := store.Create(worker); err != nil {
		t.Fatalf("create worker manifest: %v", err)
	}

	client := tmux.NewClient(runnerWithLiveSessions(map[string]bool{
		"qm-master": true,
		"qm-worker": true,
	}))
	snapshot, err := NewLiveSessionFetcher(client, store)(SessionInfo{ID: "qm-master"})
	if err != nil {
		t.Fatalf("fetch: %v", err)
	}

	rows := make(map[string]SessionRow, len(snapshot.Sessions))
	for _, row := range snapshot.Sessions {
		rows[row.ID] = row
	}
	if got := rows["qm-worker"].DisplayColor; got != "cyan" {
		t.Fatalf("worker DisplayColor = %q, want inherited cyan", got)
	}
}

func TestLiveSessionFetcherDoesNotInventWorkerDisplayColor(t *testing.T) {
	setTestStateRoot(t)

	store, err := state.NewStore(t.TempDir())
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	if err := store.Create(state.Manifest{
		SessionID:   "qm-master",
		SessionType: "master",
		Workers:     []string{"qm-worker"},
	}); err != nil {
		t.Fatalf("create master manifest: %v", err)
	}
	worker := state.Manifest{SessionID: "qm-worker"}
	worker.SetExtra("parent_session", "qm-master")
	if err := store.Create(worker); err != nil {
		t.Fatalf("create worker manifest: %v", err)
	}

	client := tmux.NewClient(runnerWithLiveSessions(map[string]bool{
		"qm-master": true,
		"qm-worker": true,
	}))
	snapshot, err := NewLiveSessionFetcher(client, store)(SessionInfo{ID: "qm-master"})
	if err != nil {
		t.Fatalf("fetch: %v", err)
	}

	rows := make(map[string]SessionRow, len(snapshot.Sessions))
	for _, row := range snapshot.Sessions {
		rows[row.ID] = row
	}
	if got := rows["qm-worker"].DisplayColor; got != "" {
		t.Fatalf("worker DisplayColor = %q, want empty when master has no display color", got)
	}
}

// writeTrackerStateFixture writes a state.json fixture into the per-test
// state root for the given session.
func writeTrackerStateFixture(t *testing.T, sessionID, paneState, activity, lastKind string, lastEvent time.Time) {
	t.Helper()
	root := os.Getenv("QUESTMASTER_STATE_ROOT")
	if root == "" {
		t.Fatalf("QUESTMASTER_STATE_ROOT must be set by the test")
	}
	dir := filepath.Join(root, sessionID)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("mkdir state dir: %v", err)
	}
	doc := map[string]any{
		"session_id": sessionID,
		"version":    1,
		"seen_at":    time.Now().UTC(),
		"panes": map[string]any{
			"primary": map[string]any{
				"role":       "primary",
				"agent":      "claude",
				"state":      paneState,
				"activity":   activity,
				"last_event": lastEvent,
				"last_kind":  lastKind,
			},
		},
	}
	data, err := json.Marshal(doc)
	if err != nil {
		t.Fatalf("marshal state.json: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "state.json"), data, 0o644); err != nil {
		t.Fatalf("write state.json: %v", err)
	}
}

func TestLiveSessionFetcherPopulatesSnippetFromStateJSON(t *testing.T) {
	setTestStateRoot(t)

	store, err := state.NewStore(t.TempDir())
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	for _, manifest := range []state.Manifest{
		{SessionID: "qm-a", Agents: []state.AgentManifest{{Name: "claude", Role: "primary"}}},
		{SessionID: "qm-b", Agents: []state.AgentManifest{{Name: "claude", Role: "primary"}}},
	} {
		if err := store.Create(manifest); err != nil {
			t.Fatalf("create manifest %s: %v", manifest.SessionID, err)
		}
	}

	now := time.Now()
	writeTrackerStateFixture(t, "qm-a", "working", "Bash: make build", "PreToolUse", now)
	writeTrackerStateFixture(t, "qm-b", "working", "Edit main.go", "PreToolUse", now)

	runner := &recordingRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if args[0] == "list-sessions" {
			return "qm-a\nqm-b", nil
		}
		if args[0] == "capture-pane" {
			t.Fatalf("Phase 2 fetcher must not call capture-pane")
		}
		return "", &tmux.ExitError{Code: 1}
	}}
	client := tmux.NewClient(runner)

	tm := NewTrackerModel(SessionInfo{ID: "qm-a"}, NewLiveSessionFetcher(client, store), &fakeActions{})
	snap, err := NewLiveSessionFetcher(client, store)(SessionInfo{ID: "qm-a"})
	if err != nil {
		t.Fatalf("fetch: %v", err)
	}
	tm.applySnapshot(snap)

	rows := make(map[string]SessionRow, len(tm.sessions))
	for _, row := range tm.sessions {
		rows[row.ID] = row
	}
	if rows["qm-a"].Snippet != "Bash: make build" {
		t.Fatalf("qm-a snippet = %q, want %q", rows["qm-a"].Snippet, "Bash: make build")
	}
	if rows["qm-b"].Snippet != "Edit main.go" {
		t.Fatalf("qm-b snippet = %q, want %q", rows["qm-b"].Snippet, "Edit main.go")
	}
	if rows["qm-a"].State != "working" {
		t.Fatalf("qm-a state = %q, want working", rows["qm-a"].State)
	}

	for _, call := range runner.calls {
		if len(call) > 0 && call[0] == "capture-pane" {
			t.Fatalf("unexpected capture-pane call: %v", call)
		}
	}
}

func setupTrackerTest(t *testing.T) (*state.Store, *tmux.Client, *session.Service, *message.Service) {
	t.Helper()
	store, err := state.NewStore(t.TempDir())
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	client := tmux.NewClient(allDeadRunner())
	sessionSvc := session.NewService(store, client, t.TempDir())
	messageSvc := message.NewService(store, client)
	return store, client, sessionSvc, messageSvc
}

func TestDeleteGhostWorkerNoManifest(t *testing.T) {
	t.Parallel()

	store, client, sessionSvc, messageSvc := setupTrackerTest(t)
	if err := store.Create(state.Manifest{SessionID: "qm-master", SessionType: "master"}); err != nil {
		t.Fatalf("create master: %v", err)
	}
	if err := store.AddWorker("qm-master", "qm-ghost"); err != nil {
		t.Fatalf("add ghost: %v", err)
	}

	actions := NewLiveTrackerActions(sessionSvc, messageSvc, client, store)
	if err := actions.Delete(t.Context(), "qm-master", "qm-ghost"); err != nil {
		t.Fatalf("delete ghost: %v", err)
	}

	workers, err := store.GetWorkers("qm-master")
	if err != nil {
		t.Fatalf("get workers: %v", err)
	}
	if len(workers) != 0 {
		t.Fatalf("expected ghost removal, got %#v", workers)
	}
}

func TestDeleteMasterUsesSessionCascade(t *testing.T) {
	t.Parallel()

	store, client, sessionSvc, messageSvc := setupTrackerTest(t)
	if err := store.Create(state.Manifest{SessionID: "qm-master", SessionType: "master"}); err != nil {
		t.Fatalf("create master: %v", err)
	}
	if err := store.Create(state.Manifest{
		SessionID: "qm-worker",
		Extra:     map[string]json.RawMessage{"parent_session": json.RawMessage(`"qm-master"`)},
	}); err != nil {
		t.Fatalf("create worker: %v", err)
	}
	if err := store.AddWorker("qm-master", "qm-worker"); err != nil {
		t.Fatalf("add worker: %v", err)
	}

	actions := NewLiveTrackerActions(sessionSvc, messageSvc, client, store)
	if err := actions.Delete(t.Context(), "", "qm-master"); err != nil {
		t.Fatalf("delete master: %v", err)
	}

	for _, sessionID := range []string{"qm-master", "qm-worker"} {
		if _, err := store.Read(sessionID); err == nil {
			t.Fatalf("manifest %s still exists", sessionID)
		}
	}
}

// Input order encodes newest-first (caller sorts by CreatedAt desc). The
// output should interleave masters and standalones at the top level by that
// same order, with workers nested under their master and orphans last.
func TestOrderSessionRowsInterleavesMastersAndStandalones(t *testing.T) {
	t.Parallel()

	rows := []SessionRow{
		{ID: "standalone-new", SessionType: "standalone"},
		{ID: "master-mid", SessionType: "master"},
		{ID: "worker-mid-b", SessionType: "worker", ParentID: "master-mid"},
		{ID: "worker-mid-a", SessionType: "worker", ParentID: "master-mid"},
		{ID: "standalone-old", SessionType: "standalone"},
		{ID: "master-old", SessionType: "master"},
		{ID: "orphan", SessionType: "worker", ParentID: "missing-parent"},
	}

	got := orderSessionRows(rows)
	gotIDs := make([]string, len(got))
	for i, row := range got {
		gotIDs[i] = row.ID
	}

	want := []string{
		"standalone-new",
		"master-mid",
		"worker-mid-b",
		"worker-mid-a",
		"standalone-old",
		"master-old",
		"orphan",
	}
	if len(gotIDs) != len(want) {
		t.Fatalf("len mismatch: got %v, want %v", gotIDs, want)
	}
	for i := range want {
		if gotIDs[i] != want[i] {
			t.Fatalf("order mismatch at %d: got %v, want %v", i, gotIDs, want)
		}
	}
}
