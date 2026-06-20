//go:build linux || darwin

package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
)

// ---------------------------------------------------------------------------
// Mock tmux runner
// ---------------------------------------------------------------------------

type mockRunner struct {
	fn func(ctx context.Context, args ...string) (string, error)
}

func (m *mockRunner) Run(ctx context.Context, args ...string) (string, error) {
	return m.fn(ctx, args...)
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

func setupStore(t *testing.T) *state.Store {
	t.Helper()
	dir := t.TempDir()
	store, err := state.NewStore(dir)
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	return store
}

func prependStubQuestmasterToPath(t *testing.T) {
	t.Helper()
	binDir := t.TempDir()
	stubPath := filepath.Join(binDir, "questmaster")
	if err := os.WriteFile(stubPath, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatalf("write questmaster stub: %v", err)
	}
	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))
}

func createManifest(t *testing.T, store *state.Store, id, title, cwd, sessionType string) {
	t.Helper()
	m := state.Manifest{
		SessionID:   id,
		Title:       title,
		Cwd:         cwd,
		SessionType: sessionType,
	}
	if err := store.Create(m); err != nil {
		t.Fatalf("create manifest %s: %v", id, err)
	}
}

func runCmd(t *testing.T, store *state.Store, runner tmux.Runner, args ...string) string {
	t.Helper()
	return runCmdInput(t, store, runner, nil, args...)
}

func runCmdInput(t *testing.T, store *state.Store, runner tmux.Runner, in io.Reader, args ...string) string {
	t.Helper()
	client := tmux.NewClient(runner)
	root := NewRootCmd(
		WithTUILauncher(func() error { return nil }),
		WithDeps(store, client),
	)
	var out bytes.Buffer
	if in != nil {
		root.SetIn(in)
	}
	root.SetOut(&out)
	root.SetErr(&bytes.Buffer{})
	root.SetArgs(args)
	if err := root.Execute(); err != nil {
		t.Fatalf("execute %v: %v", args, err)
	}
	return out.String()
}

func runCmdErr(t *testing.T, store *state.Store, runner tmux.Runner, args ...string) (string, error) {
	t.Helper()
	return runCmdInputErr(t, store, runner, nil, args...)
}

func runCmdInputErr(t *testing.T, store *state.Store, runner tmux.Runner, in io.Reader, args ...string) (string, error) {
	t.Helper()
	client := tmux.NewClient(runner)
	root := NewRootCmd(
		WithTUILauncher(func() error { return nil }),
		WithDeps(store, client),
	)
	var out bytes.Buffer
	if in != nil {
		root.SetIn(in)
	}
	root.SetOut(&out)
	root.SetErr(&bytes.Buffer{})
	root.SetArgs(args)
	err := root.Execute()
	return out.String(), err
}

// sessionsRunner returns a mock that reports the given sessions as live.
func sessionsRunner(live ...string) *mockRunner {
	liveSet := make(map[string]bool, len(live))
	for _, sessionID := range live {
		liveSet[sessionID] = true
	}
	return &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) >= 1 && args[0] == "list-sessions" {
			if len(live) == 0 {
				return "", &tmux.ExitError{Code: 1}
			}
			return strings.Join(live, "\n"), nil
		}
		if len(args) >= 1 && args[0] == "has-session" {
			target := args[len(args)-1]
			if liveSet[target] {
				return "", nil
			}
			return "", &tmux.ExitError{Code: 1}
		}
		return "", &tmux.ExitError{Code: 1}
	}}
}

// ageManifest sets the mtime of a manifest file to days ago.
func ageManifest(t *testing.T, store *state.Store, id string, days int) {
	t.Helper()
	path := filepath.Join(store.Root(), id+".json")
	old := time.Now().Add(-time.Duration(days) * 24 * time.Hour)
	if err := os.Chtimes(path, old, old); err != nil {
		t.Fatalf("age manifest: %v", err)
	}
}

func writeAgentConfig(t *testing.T, _ string) {
	t.Helper()
	t.Setenv("CLAUDE_BIN", "/bin/sh")
	t.Setenv("CODEX_BIN", "/bin/sh")
	t.Setenv("PI_BIN", "/bin/sh")
}

func decodeListOutput(t *testing.T, out string) listJSONOutput {
	t.Helper()
	var got listJSONOutput
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("list output is not JSON: %v\n%s", err, out)
	}
	return got
}

func decodeStatusOutput(t *testing.T, out string) statusJSONOutput {
	t.Helper()
	var got statusJSONOutput
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("status output is not JSON: %v\n%s", err, out)
	}
	return got
}

// ---------------------------------------------------------------------------
// list tests
// ---------------------------------------------------------------------------

func TestList_NoSessions(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	out := runCmd(t, store, sessionsRunner(), "list")
	got := decodeListOutput(t, out)
	if len(got.Active) != 0 || len(got.Resumable) != 0 {
		t.Fatalf("expected no sessions, got: %#v", got)
	}
}

func TestColorCommands_UpdateSessionAndRepo(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-color", "color", t.TempDir(), "standalone")

	sessionOut := runCmd(t, store, sessionsRunner(), "session", "color", "qm-color", "violet")
	var sessionResp struct {
		SessionID string `json:"session_id"`
		Color     string `json:"color"`
		Recolored bool   `json:"recolored"`
	}
	if err := json.Unmarshal([]byte(sessionOut), &sessionResp); err != nil {
		t.Fatalf("session color output is not JSON: %v\n%s", err, sessionOut)
	}
	if sessionResp.SessionID != "qm-color" || sessionResp.Color != "violet" || !sessionResp.Recolored {
		t.Fatalf("session color response = %#v, want qm-color violet", sessionResp)
	}
	manifest, err := store.Read("qm-color")
	if err != nil {
		t.Fatalf("read session: %v", err)
	}
	if manifest.DisplayColor() != "violet" {
		t.Fatalf("session display color = %q, want violet", manifest.DisplayColor())
	}

	repoIdentity := "/repo/.git"
	repoOut := runCmd(t, store, sessionsRunner(), "repo", "color", repoIdentity, "pink")
	var repoResp struct {
		RepoIdentity string `json:"repo_identity"`
		Color        string `json:"color"`
		Recolored    bool   `json:"recolored"`
	}
	if err := json.Unmarshal([]byte(repoOut), &repoResp); err != nil {
		t.Fatalf("repo color output is not JSON: %v\n%s", err, repoOut)
	}
	if repoResp.RepoIdentity != repoIdentity || repoResp.Color != "pink" || !repoResp.Recolored {
		t.Fatalf("repo color response = %#v, want pink", repoResp)
	}
	rc, ok, err := state.NewRepoColorStore(store.Root()).Get(repoIdentity)
	if err != nil {
		t.Fatalf("get repo color: %v", err)
	}
	if !ok || rc.Color != "pink" {
		t.Fatalf("repo color = %#v ok=%v, want pink", rc, ok)
	}

	runCmd(t, store, sessionsRunner(), "repo", "color", repoIdentity, "")
	if _, ok, err := state.NewRepoColorStore(store.Root()).Get(repoIdentity); err != nil || ok {
		t.Fatalf("repo color after clear ok=%v err=%v, want cleared", ok, err)
	}

	if _, err := runCmdErr(t, store, sessionsRunner(), "session", "color", "qm-color", "brown"); err == nil {
		t.Fatal("session color accepted invalid color")
	}
}

func TestList_ActiveSessions(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-abc", "my-project", "/home/user/code", "regular")
	createManifest(t, store, "qm-def", "other-work", "/home/user/other", "master")

	out := runCmd(t, store, sessionsRunner("qm-abc", "qm-def"), "list")
	got := decodeListOutput(t, out)
	if len(got.Active) != 2 {
		t.Fatalf("active sessions = %#v, want 2", got.Active)
	}
	if got.Active[0].SessionID != "qm-abc" || got.Active[0].Title != "my-project" {
		t.Fatalf("first active session mismatch: %#v", got.Active[0])
	}
	if got.Active[1].SessionID != "qm-def" || got.Active[1].SessionType != "master" {
		t.Fatalf("second active session mismatch: %#v", got.Active[1])
	}
}

func TestList_JSON(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-live", "active", "/tmp/a", "regular")
	createManifest(t, store, "qm-stale", "stopped", "/tmp/b", "master")

	out := runCmd(t, store, sessionsRunner("qm-live"), "list")

	var got struct {
		Active []struct {
			SessionID string `json:"session_id"`
			Title     string `json:"title"`
			Cwd       string `json:"cwd"`
			Live      bool   `json:"live"`
		} `json:"active"`
		Resumable []struct {
			SessionID   string `json:"session_id"`
			SessionType string `json:"session_type"`
			Live        bool   `json:"live"`
		} `json:"resumable"`
	}
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("list output is not JSON: %v\n%s", err, out)
	}
	if len(got.Active) != 1 || got.Active[0].SessionID != "qm-live" || !got.Active[0].Live || got.Active[0].Title != "active" {
		t.Fatalf("active JSON mismatch: %#v", got.Active)
	}
	if len(got.Resumable) != 1 || got.Resumable[0].SessionID != "qm-stale" || got.Resumable[0].Live {
		t.Fatalf("resumable JSON mismatch: %#v", got.Resumable)
	}
}

func TestList_StaleAndActive(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-live", "active", "/tmp/a", "regular")
	createManifest(t, store, "qm-stale", "stopped", "/tmp/b", "regular")

	out := runCmd(t, store, sessionsRunner("qm-live"), "list")
	got := decodeListOutput(t, out)
	if len(got.Active) != 1 || got.Active[0].SessionID != "qm-live" {
		t.Fatalf("active sessions mismatch: %#v", got.Active)
	}
	if len(got.Resumable) != 1 || got.Resumable[0].SessionID != "qm-stale" {
		t.Fatalf("resumable sessions mismatch: %#v", got.Resumable)
	}
}

func TestList_StaleOnly(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-old", "old-work", "/tmp/old", "regular")

	out := runCmd(t, store, sessionsRunner(), "list")
	got := decodeListOutput(t, out)
	if len(got.Active) != 0 || len(got.Resumable) != 1 || got.Resumable[0].SessionID != "qm-old" {
		t.Fatalf("stale-only list mismatch: %#v", got)
	}
}

func TestList_ActivePreservesTmuxOrder(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-z", "zulu", "/tmp/z", "regular")
	createManifest(t, store, "qm-a", "alpha", "/tmp/a", "regular")
	createManifest(t, store, "qm-m", "mike", "/tmp/m", "regular")

	// Tmux reports in z, a, m order
	out := runCmd(t, store, sessionsRunner("qm-z", "qm-a", "qm-m"), "list")
	got := decodeListOutput(t, out)
	if len(got.Active) != 3 {
		t.Fatalf("active sessions = %#v, want 3", got.Active)
	}
	for i, want := range []string{"qm-z", "qm-a", "qm-m"} {
		if got.Active[i].SessionID != want {
			t.Fatalf("active[%d] = %q, want %q (all: %#v)", i, got.Active[i].SessionID, want, got.Active)
		}
	}
}

// ---------------------------------------------------------------------------
// status tests
// ---------------------------------------------------------------------------

func TestStatus_ActiveSession(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-abc", "my-project", "/home/user/code", "regular")

	out := runCmd(t, store, sessionsRunner("qm-abc"), "status", "qm-abc")
	got := decodeStatusOutput(t, out)
	if got.SessionID != "qm-abc" || got.Status != "active" {
		t.Fatalf("status mismatch: %#v", got)
	}
	if got.Manifest.Title != "my-project" || got.Manifest.Cwd != "/home/user/code" {
		t.Fatalf("manifest mismatch: %#v", got.Manifest)
	}
}

func TestStatus_JSON(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-abc", "my-project", "/home/user/code", "master")
	if err := store.AddWorker("qm-abc", "qm-w1"); err != nil {
		t.Fatal(err)
	}

	out := runCmd(t, store, sessionsRunner("qm-abc"), "status", "qm-abc")

	var got struct {
		SessionID string `json:"session_id"`
		Status    string `json:"status"`
		Manifest  struct {
			Present     bool     `json:"present"`
			SessionType string   `json:"session_type"`
			Title       string   `json:"title"`
			Cwd         string   `json:"cwd"`
			Workers     []string `json:"workers"`
		} `json:"manifest"`
	}
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("status output is not JSON: %v\n%s", err, out)
	}
	if got.SessionID != "qm-abc" || got.Status != "active" {
		t.Fatalf("status JSON mismatch: %#v", got)
	}
	if !got.Manifest.Present || got.Manifest.SessionType != "master" || got.Manifest.Title != "my-project" || got.Manifest.Cwd != "/home/user/code" {
		t.Fatalf("manifest JSON mismatch: %#v", got.Manifest)
	}
	if len(got.Manifest.Workers) != 1 || got.Manifest.Workers[0] != "qm-w1" {
		t.Fatalf("workers JSON mismatch: %#v", got.Manifest.Workers)
	}
}

func TestStatus_AcceptsQMIDs(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-abc", "my-project", "/home/user/code", "regular")

	out := runCmd(t, store, sessionsRunner("qm-abc"), "status", "qm-abc")
	got := decodeStatusOutput(t, out)
	if got.SessionID != "qm-abc" || got.Status != "active" {
		t.Fatalf("status mismatch: %#v", got)
	}
}

func TestStatus_StaleSession(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-old", "stale-project", "/tmp/old", "regular")

	out := runCmd(t, store, sessionsRunner(), "status", "qm-old")
	got := decodeStatusOutput(t, out)
	if got.SessionID != "qm-old" || got.Status != "stopped" {
		t.Fatalf("status mismatch: %#v", got)
	}
}

func TestStatus_UsesHookDerivedPaneState(t *testing.T) {
	setTestStateRoot(t)
	store := setupStore(t)

	tests := []struct {
		name      string
		sessionID string
		live      bool
		state     string
		want      string
	}{
		{
			name:      "live working state",
			sessionID: "qm-status-working",
			live:      true,
			state:     "working",
			want:      "working",
		},
		{
			name:      "live idle state",
			sessionID: "qm-status-idle",
			live:      true,
			state:     "idle",
			want:      "idle",
		},
		{
			name:      "live without hook state falls back to active",
			sessionID: "qm-status-hookless",
			live:      true,
			want:      "active",
		},
		{
			name:      "dead session ignores hook state",
			sessionID: "qm-status-dead",
			state:     "working",
			want:      "stopped",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			createManifest(t, store, tc.sessionID, tc.sessionID, "/tmp", "regular")
			if tc.state != "" {
				writeSessionStateFixture(t, tc.sessionID, tc.state, tc.state, "PreToolUse", time.Now().UTC())
			}

			var live []string
			if tc.live {
				live = append(live, tc.sessionID)
			}
			out := runCmd(t, store, sessionsRunner(live...), "status", tc.sessionID)
			got := decodeStatusOutput(t, out)
			if got.Status != tc.want {
				t.Fatalf("status = %q, want %q (output: %s)", got.Status, tc.want, out)
			}
		})
	}
}

func TestStatus_MissingManifest(t *testing.T) {
	t.Parallel()
	store := setupStore(t)

	_, err := runCmdErr(t, store, sessionsRunner(), "status", "qm-ghost")
	if err == nil {
		t.Fatal("expected error for missing manifest")
	}
}

func TestStatus_MasterWithWorkers(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-master", "orchestrator", "/tmp/m", "master")
	if err := store.AddWorker("qm-master", "qm-w1"); err != nil {
		t.Fatal(err)
	}
	if err := store.AddWorker("qm-master", "qm-w2"); err != nil {
		t.Fatal(err)
	}

	out := runCmd(t, store, sessionsRunner("qm-master"), "status", "qm-master")
	got := decodeStatusOutput(t, out)
	if got.Manifest.SessionType != "master" {
		t.Fatalf("session type = %q, want master", got.Manifest.SessionType)
	}
	if strings.Join(got.Manifest.Workers, ",") != "qm-w1,qm-w2" {
		t.Fatalf("workers = %#v, want qm-w1/qm-w2", got.Manifest.Workers)
	}
}

func TestStatus_NoArgs(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	_, err := runCmdErr(t, store, sessionsRunner(), "status")
	if err == nil {
		t.Fatal("expected error when no session ID given")
	}
}

// ---------------------------------------------------------------------------
// prune tests
// ---------------------------------------------------------------------------

func TestPrune_RemovesStaleManifests(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-stale", "old", "/tmp/old", "regular")
	ageManifest(t, store, "qm-stale", 8)

	out := runCmd(t, store, sessionsRunner(), "prune")
	var pruned pruneResult
	if err := json.Unmarshal([]byte(out), &pruned); err != nil {
		t.Fatalf("prune output is not JSON: %v\n%s", err, out)
	}
	if pruned.Pruned != 1 {
		t.Fatalf("pruned = %d, want 1", pruned.Pruned)
	}
	if _, err := store.Read("qm-stale"); err == nil {
		t.Fatal("expected manifest to be deleted")
	}
}

func TestPrune_SkipsLiveSessions(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-live", "active", "/tmp/a", "regular")
	ageManifest(t, store, "qm-live", 8)

	out := runCmd(t, store, sessionsRunner("qm-live"), "prune")
	if strings.Contains(out, "Pruned") {
		t.Fatalf("should not prune live session, got: %s", out)
	}
	if _, err := store.Read("qm-live"); err != nil {
		t.Fatal("live manifest should still exist")
	}
}

func TestPrune_SkipsMasterWithWorkers(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-master", "orch", "/tmp/m", "master")
	if err := store.AddWorker("qm-master", "qm-w1"); err != nil {
		t.Fatal(err)
	}
	ageManifest(t, store, "qm-master", 8)

	out := runCmd(t, store, sessionsRunner(), "prune")
	var pruned pruneResult
	if err := json.Unmarshal([]byte(out), &pruned); err != nil {
		t.Fatalf("prune output is not JSON: %v\n%s", err, out)
	}
	if pruned.Pruned != 0 {
		t.Fatalf("pruned = %d, want 0", pruned.Pruned)
	}
	if _, err := store.Read("qm-master"); err != nil {
		t.Fatal("master manifest should still exist")
	}
}

func TestPrune_KeepsRecentManifests(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-recent", "new", "/tmp/new", "regular")

	out := runCmd(t, store, sessionsRunner(), "prune")
	var pruned pruneResult
	if err := json.Unmarshal([]byte(out), &pruned); err != nil {
		t.Fatalf("prune output is not JSON: %v\n%s", err, out)
	}
	if pruned.Pruned != 0 {
		t.Fatalf("pruned = %d, want 0", pruned.Pruned)
	}
	if _, err := store.Read("qm-recent"); err != nil {
		t.Fatal("recent manifest should still exist")
	}
}

func TestPrune_MixedStaleAndRecent(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-old", "old", "/tmp/old", "regular")
	createManifest(t, store, "qm-new", "new", "/tmp/new", "regular")
	ageManifest(t, store, "qm-old", 8)

	out := runCmd(t, store, sessionsRunner(), "prune")
	var pruned pruneResult
	if err := json.Unmarshal([]byte(out), &pruned); err != nil {
		t.Fatalf("prune output is not JSON: %v\n%s", err, out)
	}
	if pruned.Pruned != 1 {
		t.Fatalf("pruned = %d, want 1", pruned.Pruned)
	}
	if _, err := store.Read("qm-old"); err == nil {
		t.Fatal("old manifest should be deleted")
	}
	if _, err := store.Read("qm-new"); err != nil {
		t.Fatal("new manifest should still exist")
	}
}

// ---------------------------------------------------------------------------
// Regression: status on live session without manifest (F1)
// ---------------------------------------------------------------------------

func TestStatus_LiveSessionNoManifest(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	out := runCmd(t, store, sessionsRunner("qm-live"), "status", "qm-live")
	got := decodeStatusOutput(t, out)
	if got.SessionID != "qm-live" || got.Status != "active" {
		t.Fatalf("status mismatch: %#v", got)
	}
	if got.Manifest.Present || got.Manifest.Error != "missing" {
		t.Fatalf("manifest = %#v, want missing", got.Manifest)
	}
}

func TestStatus_LiveSessionCorruptManifest(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	// Write corrupt manifest
	corrupt := filepath.Join(store.Root(), "qm-bad.json")
	if err := os.WriteFile(corrupt, []byte(`{invalid`), 0o644); err != nil {
		t.Fatalf("write corrupt: %v", err)
	}

	out := runCmd(t, store, sessionsRunner("qm-bad"), "status", "qm-bad")
	got := decodeStatusOutput(t, out)
	if got.Status != "active" {
		t.Fatalf("status = %q, want active", got.Status)
	}
	if !got.Manifest.Corrupt {
		t.Fatalf("manifest = %#v, want corrupt", got.Manifest)
	}
}

// ---------------------------------------------------------------------------
// Regression: list sorts stale sessions by mtime newest first (F2)
// ---------------------------------------------------------------------------

func TestList_StaleSortedByMtime(t *testing.T) {
	t.Parallel()
	store := setupStore(t)

	// Create 12 stale manifests with different ages
	for i := range 12 {
		id := fmt.Sprintf("qm-%c", 'a'+i)
		createManifest(t, store, id, "", "/tmp", "regular")
	}
	// Make qm-k and qm-l the newest (age 1 day), rest are older (age 3 days)
	for i := range 12 {
		id := fmt.Sprintf("qm-%c", 'a'+i)
		if id == "qm-k" || id == "qm-l" {
			ageManifest(t, store, id, 1)
		} else {
			ageManifest(t, store, id, 3)
		}
	}

	out := runCmd(t, store, sessionsRunner(), "list")
	got := decodeListOutput(t, out)
	if len(got.Resumable) != 12 {
		t.Fatalf("resumable sessions = %d, want 12", len(got.Resumable))
	}
	firstTwo := map[string]bool{
		got.Resumable[0].SessionID: true,
		got.Resumable[1].SessionID: true,
	}
	if !firstTwo["qm-k"] || !firstTwo["qm-l"] {
		t.Fatalf("first two resumable sessions = %#v, want qm-k/qm-l", got.Resumable[:2])
	}
}

// ---------------------------------------------------------------------------
// Regression: prune removes corrupt manifest files (F3)
// ---------------------------------------------------------------------------

func TestPrune_RemovesCorruptManifests(t *testing.T) {
	t.Parallel()
	store := setupStore(t)

	// Write a corrupt manifest file directly
	corrupt := filepath.Join(store.Root(), "qm-corrupt.json")
	if err := os.WriteFile(corrupt, []byte(`{invalid json`), 0o644); err != nil {
		t.Fatalf("write corrupt: %v", err)
	}
	// Age it past the threshold
	old := time.Now().Add(-8 * 24 * time.Hour)
	if err := os.Chtimes(corrupt, old, old); err != nil {
		t.Fatalf("age corrupt: %v", err)
	}

	out := runCmd(t, store, sessionsRunner(), "prune")
	var pruned pruneResult
	if err := json.Unmarshal([]byte(out), &pruned); err != nil {
		t.Fatalf("prune output is not JSON: %v\n%s", err, out)
	}
	if pruned.Pruned != 1 {
		t.Fatalf("pruned = %d, want 1", pruned.Pruned)
	}
	if _, err := os.Stat(corrupt); err == nil {
		t.Fatal("corrupt manifest should have been removed")
	}
}

// ---------------------------------------------------------------------------
// Regression: list on nonexistent state dir does not create it (Codex F1)
// ---------------------------------------------------------------------------

func TestList_NonexistentStateDir_NoCreate(t *testing.T) {
	t.Parallel()
	dir := filepath.Join(t.TempDir(), "does-not-exist")
	store := state.OpenStore(dir)

	out := runCmd(t, store, sessionsRunner(), "list")
	got := decodeListOutput(t, out)
	if len(got.Active) != 0 || len(got.Resumable) != 0 {
		t.Fatalf("expected empty list, got: %#v", got)
	}
	if _, err := os.Stat(dir); err == nil {
		t.Fatal("list should not have created the state directory")
	}
}

// ---------------------------------------------------------------------------
// Regression: status rejects non-questmaster session IDs (Codex F2)
// ---------------------------------------------------------------------------

func TestStatus_NonQuestmasterSession_Rejected(t *testing.T) {
	t.Parallel()
	store := setupStore(t)

	_, err := runCmdErr(t, store, sessionsRunner("dev"), "status", "dev")
	if err == nil {
		t.Fatal("expected error for non-questmaster session ID")
	}
}
