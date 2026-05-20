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

	"github.com/anthropics/ai-party/tools/party-cli/internal/agent"
	"github.com/anthropics/ai-party/tools/party-cli/internal/claudetodos"
	"github.com/anthropics/ai-party/tools/party-cli/internal/message"
	"github.com/anthropics/ai-party/tools/party-cli/internal/piactivity"
	"github.com/anthropics/ai-party/tools/party-cli/internal/session"
	"github.com/anthropics/ai-party/tools/party-cli/internal/state"
	"github.com/anthropics/ai-party/tools/party-cli/internal/tmux"
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

func writePiSidecar(t *testing.T, sessionID string, state piactivity.State) {
	t.Helper()

	path := piactivity.Path(sessionID)
	if path == "" {
		t.Fatalf("invalid Pi activity sidecar path for %q", sessionID)
	}
	t.Cleanup(func() {
		_ = os.Remove(path)
	})

	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir sidecar dir: %v", err)
	}
	data, err := json.Marshal(state)
	if err != nil {
		t.Fatalf("marshal sidecar: %v", err)
	}
	if err := os.WriteFile(path, append(data, '\n'), 0o644); err != nil {
		t.Fatalf("write sidecar: %v", err)
	}
}

func TestLiveSessionFetcherSkipsTmuxCapturePane(t *testing.T) {
	t.Setenv("PARTY_STATE_ROOT", t.TempDir())

	store, err := state.NewStore(t.TempDir())
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	if err := store.Create(state.Manifest{
		PartyID: "party-active",
		Agents:  []state.AgentManifest{{Name: "claude", Role: "primary"}},
	}); err != nil {
		t.Fatalf("create active manifest: %v", err)
	}
	if err := store.Create(state.Manifest{PartyID: "party-stopped"}); err != nil {
		t.Fatalf("create stopped manifest: %v", err)
	}
	writeTrackerStateFixture(t, "party-active", "working", "Edit foo.go", "PreToolUse", time.Now())

	runner := &recordingRunner{fn: func(_ context.Context, args ...string) (string, error) {
		switch args[0] {
		case "list-sessions":
			return "party-active", nil
		case "list-panes":
			t.Fatalf("Phase 2 fetcher must not call list-panes")
		case "capture-pane":
			t.Fatalf("Phase 2 fetcher must not call capture-pane")
		}
		return "", &tmux.ExitError{Code: 1}
	}}
	client := tmux.NewClient(runner)

	snapshot, err := NewLiveSessionFetcher(client, store)(SessionInfo{ID: "party-active"})
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

// writeTrackerStateFixture writes a state.json fixture into the per-test
// PARTY_STATE_ROOT for the given session.
func writeTrackerStateFixture(t *testing.T, sessionID, paneState, activity, lastKind string, lastEvent time.Time) {
	t.Helper()
	root := os.Getenv("PARTY_STATE_ROOT")
	if root == "" {
		t.Fatalf("PARTY_STATE_ROOT must be set by the test")
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

func TestLiveSessionFetcherUsesPiActivitySidecar(t *testing.T) {
	t.Parallel()

	sessionID := "party-pi-fetcher-sidecar"
	writePiSidecar(t, sessionID, piactivity.State{
		Version:     1,
		Source:      "pi",
		ID:          sessionID,
		UpdatedAtMS: time.Now().UnixMilli(),
		Busy:        true,
		Phase:       "tool",
		Snippet:     "bash: running tests",
		Recent:      []string{"Thinking...", "read: README.md", "bash: go test ./...", "ok", "bash: running tests"},
	})

	store, err := state.NewStore(t.TempDir())
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	if err := store.Create(state.Manifest{
		PartyID: sessionID,
		Agents:  []state.AgentManifest{{Name: "pi", Role: "primary"}},
	}); err != nil {
		t.Fatalf("create manifest: %v", err)
	}

	runner := &recordingRunner{fn: func(_ context.Context, args ...string) (string, error) {
		switch args[0] {
		case "list-sessions":
			return sessionID, nil
		case "list-panes":
			return sessionID + "\t1 0 primary", nil
		case "capture-pane":
			t.Fatalf("Pi sidecar should avoid pane capture")
		}
		return "", &tmux.ExitError{Code: 1}
	}}

	snapshot, err := NewLiveSessionFetcher(tmux.NewClient(runner), store)(SessionInfo{ID: sessionID})
	if err != nil {
		t.Fatalf("fetch: %v", err)
	}
	if len(snapshot.Sessions) != 1 {
		t.Fatalf("sessions: got %d, want 1", len(snapshot.Sessions))
	}

	row := snapshot.Sessions[0]
	if row.Snippet != "read: README.md\nbash: go test ./...\nok\nbash: running tests" {
		t.Fatalf("snippet = %q", row.Snippet)
	}
	if row.PrimaryActiveOverride == nil || !*row.PrimaryActiveOverride {
		t.Fatalf("expected busy active override, got %#v", row.PrimaryActiveOverride)
	}
}

func TestLiveSessionFetcherKeepsStalePiSnippetWithoutActivity(t *testing.T) {
	t.Parallel()

	sessionID := "party-pi-fetcher-stale-sidecar"
	writePiSidecar(t, sessionID, piactivity.State{
		Version:     1,
		Source:      "pi",
		ID:          sessionID,
		UpdatedAtMS: time.Now().Add(-piactivity.MaxAge - time.Second).UnixMilli(),
		Busy:        true,
		Phase:       "tool",
		Snippet:     "last useful update",
	})

	store, err := state.NewStore(t.TempDir())
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	if err := store.Create(state.Manifest{
		PartyID: sessionID,
		Agents:  []state.AgentManifest{{Name: "pi", Role: "primary"}},
	}); err != nil {
		t.Fatalf("create manifest: %v", err)
	}

	runner := runnerWithLiveSessions(map[string]bool{sessionID: true})
	snapshot, err := NewLiveSessionFetcher(tmux.NewClient(runner), store)(SessionInfo{ID: sessionID})
	if err != nil {
		t.Fatalf("fetch: %v", err)
	}
	if len(snapshot.Sessions) != 1 {
		t.Fatalf("sessions: got %d, want 1", len(snapshot.Sessions))
	}

	row := snapshot.Sessions[0]
	if row.Snippet != "last useful update" {
		t.Fatalf("snippet = %q", row.Snippet)
	}
	if row.PrimaryActiveOverride == nil || *row.PrimaryActiveOverride {
		t.Fatalf("expected stale sidecar to force inactive override, got %#v", row.PrimaryActiveOverride)
	}
}

func TestLiveSessionFetcherPopulatesSnippetFromStateJSON(t *testing.T) {
	t.Setenv("PARTY_STATE_ROOT", t.TempDir())

	store, err := state.NewStore(t.TempDir())
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	for _, manifest := range []state.Manifest{
		{PartyID: "party-a", Agents: []state.AgentManifest{{Name: "claude", Role: "primary"}}},
		{PartyID: "party-b", Agents: []state.AgentManifest{{Name: "claude", Role: "primary"}}},
	} {
		if err := store.Create(manifest); err != nil {
			t.Fatalf("create manifest %s: %v", manifest.PartyID, err)
		}
	}

	now := time.Now()
	writeTrackerStateFixture(t, "party-a", "working", "Bash: make build", "PreToolUse", now)
	writeTrackerStateFixture(t, "party-b", "working", "Edit main.go", "PreToolUse", now)

	runner := &recordingRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if args[0] == "list-sessions" {
			return "party-a\nparty-b", nil
		}
		if args[0] == "capture-pane" {
			t.Fatalf("Phase 2 fetcher must not call capture-pane")
		}
		return "", &tmux.ExitError{Code: 1}
	}}
	client := tmux.NewClient(runner)

	tm := NewTrackerModel(SessionInfo{ID: "party-a"}, NewLiveSessionFetcher(client, store), &fakeActions{})
	snap, err := NewLiveSessionFetcher(client, store)(SessionInfo{ID: "party-a"})
	if err != nil {
		t.Fatalf("fetch: %v", err)
	}
	tm.applySnapshot(snap)

	rows := make(map[string]SessionRow, len(tm.sessions))
	for _, row := range tm.sessions {
		rows[row.ID] = row
	}
	if rows["party-a"].Snippet != "Bash: make build" {
		t.Fatalf("party-a snippet = %q, want %q", rows["party-a"].Snippet, "Bash: make build")
	}
	if rows["party-b"].Snippet != "Edit main.go" {
		t.Fatalf("party-b snippet = %q, want %q", rows["party-b"].Snippet, "Edit main.go")
	}
	if rows["party-a"].State != "working" {
		t.Fatalf("party-a state = %q, want working", rows["party-a"].State)
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
	if err := store.Create(state.Manifest{PartyID: "party-master", SessionType: "master"}); err != nil {
		t.Fatalf("create master: %v", err)
	}
	if err := store.AddWorker("party-master", "party-ghost"); err != nil {
		t.Fatalf("add ghost: %v", err)
	}

	actions := NewLiveTrackerActions(sessionSvc, messageSvc, client, store)
	if err := actions.Delete(t.Context(), "party-master", "party-ghost"); err != nil {
		t.Fatalf("delete ghost: %v", err)
	}

	workers, err := store.GetWorkers("party-master")
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
	if err := store.Create(state.Manifest{PartyID: "party-master", SessionType: "master"}); err != nil {
		t.Fatalf("create master: %v", err)
	}
	if err := store.Create(state.Manifest{
		PartyID: "party-worker",
		Extra:   map[string]json.RawMessage{"parent_session": json.RawMessage(`"party-master"`)},
	}); err != nil {
		t.Fatalf("create worker: %v", err)
	}
	if err := store.AddWorker("party-master", "party-worker"); err != nil {
		t.Fatalf("add worker: %v", err)
	}

	actions := NewLiveTrackerActions(sessionSvc, messageSvc, client, store)
	if err := actions.Delete(t.Context(), "", "party-master"); err != nil {
		t.Fatalf("delete master: %v", err)
	}

	for _, sessionID := range []string{"party-master", "party-worker"} {
		if _, err := store.Read(sessionID); err == nil {
			t.Fatalf("manifest %s still exists", sessionID)
		}
	}
}

func TestLiveSessionFetcherDoesNotInventCompanionFromRegistry(t *testing.T) {
	t.Parallel()

	store, err := state.NewStore(t.TempDir())
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	client := tmux.NewClient(runnerWithLiveSessions(map[string]bool{"party-codex": true}))

	manifest := state.Manifest{
		PartyID: "party-codex",
		Agents: []state.AgentManifest{
			{Name: "codex", Role: "primary"},
		},
	}
	if err := store.Create(manifest); err != nil {
		t.Fatalf("create manifest: %v", err)
	}

	registry, err := agent.NewRegistry(agent.DefaultConfig())
	if err != nil {
		t.Fatalf("new registry: %v", err)
	}

	fetcher := NewLiveSessionFetcher(client, store)
	snapshot, err := fetcher(SessionInfo{ID: "party-codex", SessionType: "standalone", Manifest: manifest, Registry: registry})
	if err != nil {
		t.Fatalf("fetch sessions: %v", err)
	}

	if snapshot.Sessions[0].HasCompanion {
		t.Fatal("expected row to report no companion")
	}
}

func TestClaudeTodoCache(t *testing.T) {
	t.Parallel()

	base := t.TempDir()
	sessionID := "session-one"
	path := claudetodos.Path(base, sessionID)

	write := func(t *testing.T, content string) {
		t.Helper()
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			t.Fatalf("write todo file: %v", err)
		}
	}
	bump := func(t *testing.T, delta time.Duration) {
		t.Helper()
		fi, err := os.Stat(path)
		if err != nil {
			t.Fatalf("stat: %v", err)
		}
		next := fi.ModTime().Add(delta)
		if err := os.Chtimes(path, next, next); err != nil {
			t.Fatalf("chtimes: %v", err)
		}
	}

	cache := newClaudeTodoCache()

	// Missing file → not ok.
	if _, ok := cache.Fetch(base, sessionID); ok {
		t.Fatalf("expected miss for absent file")
	}

	write(t, `[{"content":"alpha","status":"in_progress"}]`)
	state1, ok := cache.Fetch(base, sessionID)
	if !ok {
		t.Fatalf("expected hit after write")
	}
	if state1.Counts.InProgress != 1 || state1.Total() != 1 {
		t.Fatalf("unexpected state: %+v", state1)
	}

	// No mtime change → same state.
	state2, _ := cache.Fetch(base, sessionID)
	if state2.Counts != state1.Counts {
		t.Fatalf("cache should return prior state unchanged, got %+v vs %+v", state2, state1)
	}

	// Overwrite with malformed JSON and bump mtime → last good retained.
	write(t, `{ not json`)
	bump(t, 2*time.Second)
	state3, ok := cache.Fetch(base, sessionID)
	if !ok {
		t.Fatalf("malformed JSON must keep last good, got miss")
	}
	if state3.Counts.InProgress != 1 {
		t.Fatalf("malformed JSON must not overwrite state, got %+v", state3)
	}

	// Repair + mtime bump → new state applies.
	write(t, `[{"content":"alpha","status":"completed"},{"content":"beta","status":"pending"}]`)
	bump(t, 4*time.Second)
	state4, ok := cache.Fetch(base, sessionID)
	if !ok {
		t.Fatalf("expected hit after repair")
	}
	if state4.Counts.Completed != 1 || state4.Counts.Pending != 1 || state4.Total() != 2 {
		t.Fatalf("repair state = %+v", state4)
	}

	// File briefly disappears (atomic rename-replace in progress): last
	// good state stays in the cache, no flicker.
	if err := os.Remove(path); err != nil {
		t.Fatalf("remove: %v", err)
	}
	state5, ok := cache.Fetch(base, sessionID)
	if !ok {
		t.Fatalf("expected hit when file vanishes transiently")
	}
	if state5.Counts != state4.Counts {
		t.Fatalf("transient stat failure must preserve last good, got %+v want %+v", state5.Counts, state4.Counts)
	}

	// Empty session ID → miss.
	if _, ok := cache.Fetch(base, ""); ok {
		t.Fatalf("expected miss for empty session id")
	}

	// Fresh cache + missing file → miss (no prior good state to keep).
	if _, ok := newClaudeTodoCache().Fetch(base, "never-seen"); ok {
		t.Fatalf("expected miss for fresh cache with absent file")
	}
}

func TestResolveClaudeTodoOverlaySkipsNonClaude(t *testing.T) {
	t.Parallel()

	cache := newClaudeTodoCache()
	baseDir := t.TempDir()

	cases := map[string]struct {
		primary agent.Agent
		status  string
	}{
		"codex primary":  {primary: &agent.Codex{}, status: "active"},
		"stopped claude": {primary: &agent.Claude{}, status: "stopped"},
		"nil primary":    {primary: nil, status: "active"},
	}

	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()

			manifest := state.Manifest{PartyID: "party-x"}
			got := resolveClaudeTodoOverlay(cache, baseDir, manifest, tc.primary, tc.status)
			if got != "" {
				t.Errorf("got %q, want empty", got)
			}
		})
	}
}

func TestResolveClaudeTodoOverlayEmptyBaseDir(t *testing.T) {
	t.Parallel()

	got := resolveClaudeTodoOverlay(newClaudeTodoCache(), "", state.Manifest{PartyID: "party-x"}, &agent.Claude{}, "active")
	if got != "" {
		t.Errorf("expected empty overlay when baseDir unset, got %q", got)
	}
}
