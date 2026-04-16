//go:build linux || darwin

package tui

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
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

func TestLiveSessionFetcherResolvesEvidenceByClaudeSessionID(t *testing.T) {
	t.Parallel()

	store, err := state.NewStore(t.TempDir())
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	client := tmux.NewClient(runnerWithLiveSessions(map[string]bool{"party-worker": true}))

	manifest := state.Manifest{
		PartyID: "party-worker",
		Title:   "bugfix",
		Extra: map[string]json.RawMessage{
			"parent_session":    json.RawMessage(`"party-master"`),
			"claude_session_id": json.RawMessage(`"claude-uuid-1"`),
		},
	}
	if err := store.Create(manifest); err != nil {
		t.Fatalf("create worker: %v", err)
	}
	writeEvidence(t, "claude-uuid-1", []string{
		`{"timestamp":"T","type":"code-critic","result":"APPROVED","diff_hash":"aaa"}`,
		`{"timestamp":"T","type":"minimizer","result":"APPROVED","diff_hash":"aaa"}`,
	})

	fetcher := NewLiveSessionFetcher(client, store)
	snapshot, err := fetcher(SessionInfo{ID: "party-worker", SessionType: "worker"})
	if err != nil {
		t.Fatalf("fetch sessions: %v", err)
	}
	if len(snapshot.Sessions) != 1 {
		t.Fatalf("expected one session row, got %d", len(snapshot.Sessions))
	}
	if snapshot.Sessions[0].Stage != StageCriticsOK {
		t.Fatalf("expected stage %q, got %q", StageCriticsOK, snapshot.Sessions[0].Stage)
	}
}

func TestLiveSessionFetcherReadsCompanionStatusForCurrentDetail(t *testing.T) {
	t.Parallel()

	store, err := state.NewStore(t.TempDir())
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	client := tmux.NewClient(runnerWithLiveSessions(map[string]bool{"party-current": true}))

	manifest := state.Manifest{
		PartyID: "party-current",
		Title:   "current",
		Agents: []state.AgentManifest{
			{Name: "claude", Role: "primary"},
			{Name: "codex", Role: "companion"},
		},
	}
	if err := store.Create(manifest); err != nil {
		t.Fatalf("create manifest: %v", err)
	}

	runtimeDir := filepath.Join("/tmp", "party-current")
	if err := os.MkdirAll(runtimeDir, 0o755); err != nil {
		t.Fatalf("mkdir runtime: %v", err)
	}
	t.Cleanup(func() { os.RemoveAll(runtimeDir) })
	if err := os.WriteFile(filepath.Join(runtimeDir, "codex-status.json"), []byte(`{"state":"idle","verdict":"APPROVED"}`), 0o644); err != nil {
		t.Fatalf("write codex status: %v", err)
	}

	fetcher := NewLiveSessionFetcher(client, store)
	snapshot, err := fetcher(SessionInfo{ID: "party-current", SessionType: "standalone", Manifest: manifest})
	if err != nil {
		t.Fatalf("fetch sessions: %v", err)
	}

	if snapshot.Current.CompanionStatus.State != CompanionIdle {
		t.Fatalf("expected idle companion, got %q", snapshot.Current.CompanionStatus.State)
	}
	if snapshot.Current.CompanionStatus.Verdict != "APPROVED" {
		t.Fatalf("expected APPROVED verdict, got %q", snapshot.Current.CompanionStatus.Verdict)
	}
}

func TestLiveSessionFetcherReadsClaudePrimaryState(t *testing.T) {
	t.Parallel()

	store, err := state.NewStore(t.TempDir())
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	client := tmux.NewClient(runnerWithLiveSessions(map[string]bool{"party-claude": true}))

	manifest := state.Manifest{
		PartyID: "party-claude",
		Agents: []state.AgentManifest{
			{Name: "claude", Role: "primary"},
		},
	}
	if err := store.Create(manifest); err != nil {
		t.Fatalf("create manifest: %v", err)
	}

	runtimeDir := filepath.Join("/tmp", "party-claude")
	if err := os.MkdirAll(runtimeDir, 0o755); err != nil {
		t.Fatalf("mkdir runtime: %v", err)
	}
	t.Cleanup(func() { os.RemoveAll(runtimeDir) })
	if err := os.WriteFile(filepath.Join(runtimeDir, "claude-state.json"), []byte(`{"state":"waiting"}`), 0o644); err != nil {
		t.Fatalf("write primary state: %v", err)
	}

	fetcher := NewLiveSessionFetcher(client, store)
	snapshot, err := fetcher(SessionInfo{ID: "party-claude", SessionType: "standalone", Manifest: manifest})
	if err != nil {
		t.Fatalf("fetch sessions: %v", err)
	}

	if snapshot.Sessions[0].PrimaryState != "waiting" {
		t.Fatalf("expected waiting primary state, got %q", snapshot.Sessions[0].PrimaryState)
	}
}

func TestLiveSessionFetcherLeavesNonClaudePrimaryStateEmpty(t *testing.T) {
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

	runtimeDir := filepath.Join("/tmp", "party-codex")
	if err := os.MkdirAll(runtimeDir, 0o755); err != nil {
		t.Fatalf("mkdir runtime: %v", err)
	}
	t.Cleanup(func() { os.RemoveAll(runtimeDir) })
	if err := os.WriteFile(filepath.Join(runtimeDir, "codex-status.json"), []byte(`{"state":"working"}`), 0o644); err != nil {
		t.Fatalf("write codex status: %v", err)
	}

	registry, err := agent.NewRegistry(&agent.Config{
		Agents: map[string]agent.AgentConfig{
			"claude": {CLI: "claude"},
			"codex":  {CLI: "codex"},
		},
		Roles: agent.RolesConfig{
			Primary: &agent.RoleConfig{Agent: "codex"},
		},
	})
	if err != nil {
		t.Fatalf("new registry: %v", err)
	}

	fetcher := NewLiveSessionFetcher(client, store)
	snapshot, err := fetcher(SessionInfo{ID: "party-codex", SessionType: "standalone", Manifest: manifest, Registry: registry})
	if err != nil {
		t.Fatalf("fetch sessions: %v", err)
	}

	if snapshot.Sessions[0].PrimaryState != "" {
		t.Fatalf("expected empty primary state for non-Claude primary, got %q", snapshot.Sessions[0].PrimaryState)
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

func TestLiveSessionFetcherReadsClaudeCompanionState(t *testing.T) {
	t.Parallel()

	store, err := state.NewStore(t.TempDir())
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	client := tmux.NewClient(runnerWithLiveSessions(map[string]bool{"party-swap": true}))

	manifest := state.Manifest{
		PartyID: "party-swap",
		Agents: []state.AgentManifest{
			{Name: "codex", Role: "primary"},
			{Name: "claude", Role: "companion"},
		},
	}
	if err := store.Create(manifest); err != nil {
		t.Fatalf("create manifest: %v", err)
	}

	runtimeDir := filepath.Join("/tmp", "party-swap")
	if err := os.MkdirAll(runtimeDir, 0o755); err != nil {
		t.Fatalf("mkdir runtime: %v", err)
	}
	t.Cleanup(func() { os.RemoveAll(runtimeDir) })
	if err := os.WriteFile(filepath.Join(runtimeDir, "claude-state.json"), []byte(`{"state":"waiting"}`), 0o644); err != nil {
		t.Fatalf("write claude status: %v", err)
	}

	fetcher := NewLiveSessionFetcher(client, store)
	snapshot, err := fetcher(SessionInfo{ID: "party-swap", SessionType: "standalone", Manifest: manifest})
	if err != nil {
		t.Fatalf("fetch sessions: %v", err)
	}

	if snapshot.Current.CompanionName != "claude" {
		t.Fatalf("expected claude companion, got %q", snapshot.Current.CompanionName)
	}
	if snapshot.Current.CompanionStatus.State != CompanionState("waiting") {
		t.Fatalf("expected waiting companion state, got %q", snapshot.Current.CompanionStatus.State)
	}
	if snapshot.Sessions[0].CompanionState != "waiting" {
		t.Fatalf("expected row waiting state, got %q", snapshot.Sessions[0].CompanionState)
	}
}
