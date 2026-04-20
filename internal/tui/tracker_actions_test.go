//go:build linux || darwin

package tui

import (
	"context"
	"sort"
	"strings"
	"testing"

	"github.com/anthropics/ai-party/tools/party-cli/internal/agent"
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

	if snapshot.Current.CompanionName != "" {
		t.Fatalf("expected no companion for no-companion session, got %q", snapshot.Current.CompanionName)
	}
	if snapshot.Sessions[0].HasCompanion {
		t.Fatal("expected row to report no companion")
	}
}

func TestLiveSessionFetcherLeavesMasterCompanionEmptyWithoutManifestEntry(t *testing.T) {
	t.Parallel()

	store, err := state.NewStore(t.TempDir())
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	client := tmux.NewClient(runnerWithLiveSessions(map[string]bool{"party-master": true}))

	manifest := state.Manifest{
		PartyID:     "party-master",
		SessionType: "master",
		Agents:      []state.AgentManifest{{Name: "claude", Role: "primary"}},
	}
	if err := store.Create(manifest); err != nil {
		t.Fatalf("create manifest: %v", err)
	}

	registry, err := agent.NewRegistry(agent.DefaultConfig())
	if err != nil {
		t.Fatalf("new registry: %v", err)
	}

	snapshot, err := NewLiveSessionFetcher(client, store)(SessionInfo{ID: "party-master", SessionType: "master", Manifest: manifest, Registry: registry})
	if err != nil {
		t.Fatalf("fetch sessions: %v", err)
	}
	if snapshot.Current.CompanionName != "" {
		t.Fatalf("expected empty companion for master without manifest entry, got %q", snapshot.Current.CompanionName)
	}
}
