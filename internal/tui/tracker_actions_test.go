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

func writeCodexRolloutFixture(t *testing.T, path, threadID, cwd, startedAt string, age time.Duration) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir rollout dir: %v", err)
	}
	record := map[string]any{
		"timestamp": startedAt,
		"type":      "session_meta",
		"payload": map[string]any{
			"id":        threadID,
			"cwd":       cwd,
			"timestamp": startedAt,
		},
	}
	line, err := json.Marshal(record)
	if err != nil {
		t.Fatalf("marshal rollout: %v", err)
	}
	if err := os.WriteFile(path, append(line, '\n'), 0o644); err != nil {
		t.Fatalf("write rollout: %v", err)
	}
	mtime := time.Now().Add(-age)
	if err := os.Chtimes(path, mtime, mtime); err != nil {
		t.Fatalf("chtimes rollout: %v", err)
	}
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

// TestLiveSessionFetcherSkipsCompanionRolloutRecovery guards the false-blink
// regression: a Claude-primary + Codex-companion session without an explicit
// codex_thread_id must not adopt an unrelated fresh Codex rollout from the
// same cwd via RecoverResumeID. Only the primary slot is permitted to recover
// from the shared rollout cache.
func TestLiveSessionFetcherSkipsCompanionRolloutRecovery(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	cwd := "/repo/app"
	dayDir := filepath.Join(home, ".codex", "sessions", time.Now().Format("2006"), time.Now().Format("01"), time.Now().Format("02"))
	writeCodexRolloutFixture(t,
		filepath.Join(dayDir, "rollout-active-thr-stranger.jsonl"),
		"thr-stranger", cwd, "2026-04-20T09:05:00Z", agent.ActivityWindow/2)

	store, err := state.NewStore(t.TempDir())
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	client := tmux.NewClient(runnerWithLiveSessions(map[string]bool{"party-claude": true}))

	manifest := state.Manifest{
		PartyID:   "party-claude",
		Cwd:       cwd,
		CreatedAt: "2026-04-20T09:04:30Z",
		Agents: []state.AgentManifest{
			{Name: "claude", Role: "primary"},
			{Name: "codex", Role: "companion"},
		},
	}
	if err := store.Create(manifest); err != nil {
		t.Fatalf("create manifest: %v", err)
	}

	snapshot, err := NewLiveSessionFetcher(client, store)(SessionInfo{ID: "party-claude"})
	if err != nil {
		t.Fatalf("fetch: %v", err)
	}
	if len(snapshot.Sessions) != 1 {
		t.Fatalf("expected 1 session row, got %d", len(snapshot.Sessions))
	}
	row := snapshot.Sessions[0]
	if row.CompanionActive {
		t.Fatal("CompanionActive: got true; companion must not inherit an unrelated rollout")
	}
	if row.isGenerating() {
		t.Fatal("isGenerating: got true; expected false with no real companion activity")
	}
}

func TestLiveSessionFetcherDetectsCodexActivityViaRecoveredResumeID(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	cwd := "/repo/app"
	dayDir := filepath.Join(home, ".codex", "sessions", time.Now().Format("2006"), time.Now().Format("01"), time.Now().Format("02"))
	writeCodexRolloutFixture(t,
		filepath.Join(dayDir, "rollout-active-thr-codex.jsonl"),
		"thr-codex", cwd, "2026-04-20T09:05:00Z", agent.ActivityWindow/2)
	writeCodexRolloutFixture(t,
		filepath.Join(dayDir, "rollout-active-thr-other.jsonl"),
		"thr-other", cwd, "2026-04-20T08:00:00Z", agent.ActivityWindow/2)

	store, err := state.NewStore(t.TempDir())
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	client := tmux.NewClient(runnerWithLiveSessions(map[string]bool{"party-codex": true}))

	manifest := state.Manifest{
		PartyID:   "party-codex",
		Cwd:       cwd,
		CreatedAt: "2026-04-20T09:04:30Z",
		Agents:    []state.AgentManifest{{Name: "codex", Role: "primary"}},
	}
	if err := store.Create(manifest); err != nil {
		t.Fatalf("create manifest: %v", err)
	}

	snapshot, err := NewLiveSessionFetcher(client, store)(SessionInfo{ID: "party-codex"})
	if err != nil {
		t.Fatalf("fetch: %v", err)
	}
	if len(snapshot.Sessions) != 1 {
		t.Fatalf("expected 1 session row, got %d", len(snapshot.Sessions))
	}
	row := snapshot.Sessions[0]
	if !row.PrimaryActive {
		t.Fatal("PrimaryActive: got false; expected Codex rollout metadata fallback to recover thread ID")
	}
	if !row.isGenerating() {
		t.Fatal("isGenerating: got false; expected true once Codex activity is recovered")
	}
}

func TestLiveSessionFetcherPersistsRecoveredCodexResumeID(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	cwd := "/repo/app"
	dayDir := filepath.Join(home, ".codex", "sessions", time.Now().Format("2006"), time.Now().Format("01"), time.Now().Format("02"))
	writeCodexRolloutFixture(t,
		filepath.Join(dayDir, "rollout-active-thr-cached.jsonl"),
		"thr-cached", cwd, "2026-04-20T09:05:00Z", agent.ActivityWindow/2)

	store, err := state.NewStore(t.TempDir())
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	client := tmux.NewClient(runnerWithLiveSessions(map[string]bool{"party-codex": true}))

	manifest := state.Manifest{
		PartyID:   "party-codex",
		Cwd:       cwd,
		CreatedAt: "2026-04-20T09:04:30Z",
		Agents:    []state.AgentManifest{{Name: "codex", Role: "primary"}},
	}
	if err := store.Create(manifest); err != nil {
		t.Fatalf("create manifest: %v", err)
	}

	if _, err := NewLiveSessionFetcher(client, store)(SessionInfo{ID: "party-codex"}); err != nil {
		t.Fatalf("fetch: %v", err)
	}

	updated, err := store.Read("party-codex")
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}
	if got := updated.ExtraString("codex_thread_id"); got != "thr-cached" {
		t.Fatalf("codex_thread_id: got %q, want %q", got, "thr-cached")
	}
}
