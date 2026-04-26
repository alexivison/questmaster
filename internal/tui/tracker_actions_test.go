//go:build linux || darwin

package tui

import (
	"context"
	"os"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/anthropics/ai-party/tools/party-cli/internal/agent"
	"github.com/anthropics/ai-party/tools/party-cli/internal/claudetodos"
	"github.com/anthropics/ai-party/tools/party-cli/internal/message"
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

func TestLiveSessionFetcherBatchesTmuxQueriesAndUsesShortCaptureTail(t *testing.T) {
	t.Parallel()

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

	runner := &recordingRunner{fn: func(_ context.Context, args ...string) (string, error) {
		switch args[0] {
		case "list-sessions":
			return "party-active", nil
		case "list-panes":
			return "party-active\t1 0 primary", nil
		case "capture-pane":
			return "❯ build status\n⎿ still working\n", nil
		default:
			return "", &tmux.ExitError{Code: 1}
		}
	}}
	client := tmux.NewClient(runner)

	snapshot, err := NewLiveSessionFetcher(client, store)(SessionInfo{ID: "party-active"})
	if err != nil {
		t.Fatalf("fetch: %v", err)
	}
	if len(snapshot.Sessions) != 2 {
		t.Fatalf("expected 2 sessions, got %d", len(snapshot.Sessions))
	}
	var activeRow SessionRow
	for _, row := range snapshot.Sessions {
		if row.ID == "party-active" {
			activeRow = row
			break
		}
	}
	if activeRow.Snippet == "" {
		t.Fatal("expected active row snippet to be captured")
	}

	counts := make(map[string]int)
	var captureArgs []string
	for _, call := range runner.calls {
		if len(call) == 0 {
			continue
		}
		counts[call[0]]++
		if call[0] == "capture-pane" {
			captureArgs = call
		}
	}
	if counts["has-session"] != 0 {
		t.Fatalf("expected no has-session calls, got %d", counts["has-session"])
	}
	if counts["list-sessions"] != 1 {
		t.Fatalf("list-sessions calls: got %d, want 1", counts["list-sessions"])
	}
	if counts["list-panes"] != 1 {
		t.Fatalf("list-panes calls: got %d, want 1", counts["list-panes"])
	}
	if counts["capture-pane"] != 1 {
		t.Fatalf("capture-pane calls: got %d, want 1", counts["capture-pane"])
	}
	if got := strings.Join(captureArgs, " "); !strings.Contains(got, "-50") {
		t.Fatalf("expected capture-pane tail to use -50, got %v", captureArgs)
	}
}

func TestLiveSessionFetcherCapturesSnippetsForEveryActiveRow(t *testing.T) {
	t.Parallel()

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

	runner := &recordingRunner{fn: func(_ context.Context, args ...string) (string, error) {
		switch args[0] {
		case "list-sessions":
			return "party-a\nparty-b", nil
		case "list-panes":
			return "party-a\t1 0 primary\nparty-b\t1 0 primary", nil
		case "capture-pane":
			switch args[2] {
			case "party-b:1.0":
				return "⏺ selected snippet\n", nil
			case "party-a:1.0":
				return "⏺ unselected snippet\n", nil
			}
		}
		return "", &tmux.ExitError{Code: 1}
	}}
	client := tmux.NewClient(runner)

	snapshot, err := NewLiveSessionFetcher(client, store)(SessionInfo{ID: "party-a"})
	if err != nil {
		t.Fatalf("fetch: %v", err)
	}

	rows := make(map[string]SessionRow, len(snapshot.Sessions))
	for _, row := range snapshot.Sessions {
		rows[row.ID] = row
	}
	if rows["party-b"].Snippet == "" {
		t.Fatal("expected party-b snippet to be captured")
	}
	if rows["party-a"].Snippet == "" {
		t.Fatal("expected party-a snippet to be captured")
	}

	captures := 0
	targets := make(map[string]bool)
	for _, call := range runner.calls {
		if len(call) > 0 && call[0] == "capture-pane" {
			captures++
			targets[call[2]] = true
		}
	}
	if captures != 2 {
		t.Fatalf("capture-pane calls: got %d, want 2", captures)
	}
	for _, target := range []string{"party-a:1.0", "party-b:1.0"} {
		if !targets[target] {
			t.Fatalf("missing capture-pane target %q; got %#v", target, targets)
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

func TestStopGhostWorkerNoManifest(t *testing.T) {
	t.Parallel()

	store, client, sessionSvc, messageSvc := setupTrackerTest(t)
	if err := store.Create(state.Manifest{PartyID: "party-master", SessionType: "master"}); err != nil {
		t.Fatalf("create master: %v", err)
	}
	if err := store.AddWorker("party-master", "party-ghost"); err != nil {
		t.Fatalf("add ghost: %v", err)
	}

	actions := NewLiveTrackerActions(sessionSvc, messageSvc, client, store)
	if err := actions.Stop(t.Context(), "party-master", "party-ghost"); err != nil {
		t.Fatalf("stop ghost: %v", err)
	}

	workers, err := store.GetWorkers("party-master")
	if err != nil {
		t.Fatalf("get workers: %v", err)
	}
	if len(workers) != 0 {
		t.Fatalf("expected ghost removal, got %#v", workers)
	}
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
