//go:build linux || darwin

package tui

import (
	"context"
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

// TestResumeIDForFallsBackToManifestExtras covers the activity-dot bug where
// fresh standalone sessions (no prior resume) leave Agents[].ResumeID empty
// but Claude's SessionStart hook writes claude_session_id into manifest
// extras. Without the extras fallback, agentActive can't locate the live
// transcript and the dot never animates during tool-use turns.
func TestResumeIDForFallsBackToManifestExtras(t *testing.T) {
	t.Parallel()

	claude := agent.NewClaude(agent.AgentConfig{})

	emptyAgentsWithExtra := state.Manifest{
		Agents: []state.AgentManifest{{Name: "claude", Role: "primary"}},
	}
	emptyAgentsWithExtra.SetExtra("claude_session_id", "sess-from-hook")

	if got := resumeIDFor(claude, emptyAgentsWithExtra); got != "sess-from-hook" {
		t.Fatalf("extras fallback: got %q, want %q", got, "sess-from-hook")
	}

	directSpec := state.Manifest{
		Agents: []state.AgentManifest{{Name: "claude", Role: "primary", ResumeID: "sess-direct"}},
	}
	directSpec.SetExtra("claude_session_id", "sess-from-hook")
	if got := resumeIDFor(claude, directSpec); got != "sess-direct" {
		t.Fatalf("Agents[].ResumeID wins: got %q, want %q", got, "sess-direct")
	}

	none := state.Manifest{
		Agents: []state.AgentManifest{{Name: "claude", Role: "primary"}},
	}
	if got := resumeIDFor(claude, none); got != "" {
		t.Fatalf("no id anywhere: got %q, want empty", got)
	}
}

// TestLiveSessionFetcherDetectsClaudeActivityViaManifestExtras proves the
// full activity chain for a fresh standalone Claude session: the only
// resume ID lives in manifest extras (written by the SessionStart hook),
// so the fetcher must consult it to locate the transcript and mark
// PrimaryActive — which in turn drives the blinking activity dot.
func TestLiveSessionFetcherDetectsClaudeActivityViaManifestExtras(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	cwd := "/some/project"
	resumeID := "sess-xyz"
	transcript := filepath.Join(home, ".claude", "projects", "-some-project", resumeID+".jsonl")
	if err := os.MkdirAll(filepath.Dir(transcript), 0o755); err != nil {
		t.Fatalf("mkdir transcripts: %v", err)
	}
	if err := os.WriteFile(transcript, []byte("{}\n"), 0o644); err != nil {
		t.Fatalf("write transcript: %v", err)
	}

	store, err := state.NewStore(t.TempDir())
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	client := tmux.NewClient(runnerWithLiveSessions(map[string]bool{"party-tool": true}))

	manifest := state.Manifest{
		PartyID: "party-tool",
		Cwd:     cwd,
		Agents:  []state.AgentManifest{{Name: "claude", Role: "primary"}},
	}
	manifest.SetExtra("claude_session_id", resumeID)
	if err := store.Create(manifest); err != nil {
		t.Fatalf("create manifest: %v", err)
	}

	snapshot, err := NewLiveSessionFetcher(client, store)(SessionInfo{ID: "party-tool"})
	if err != nil {
		t.Fatalf("fetch: %v", err)
	}
	if len(snapshot.Sessions) != 1 {
		t.Fatalf("expected 1 session row, got %d", len(snapshot.Sessions))
	}
	row := snapshot.Sessions[0]
	if !row.PrimaryActive {
		t.Fatal("PrimaryActive: got false; expected fresh transcript located via manifest extras")
	}
	if !row.isGenerating() {
		t.Fatal("isGenerating: got false; expected true once PrimaryActive flows from extras")
	}
}
