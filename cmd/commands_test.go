//go:build linux || darwin

package cmd

import (
	"bytes"
	"context"
	"fmt"
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
		SessionID:     id,
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
	client := tmux.NewClient(runner)
	root := NewRootCmd(
		WithTUILauncher(func() error { return nil }),
		WithDeps(store, client),
	)
	var out bytes.Buffer
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
	client := tmux.NewClient(runner)
	root := NewRootCmd(
		WithTUILauncher(func() error { return nil }),
		WithDeps(store, client),
	)
	var out bytes.Buffer
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

// ---------------------------------------------------------------------------
// list tests
// ---------------------------------------------------------------------------

func TestList_NoSessions(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	out := runCmd(t, store, sessionsRunner(), "list")
	if !strings.Contains(out, "No questmaster sessions found") {
		t.Fatalf("expected 'No questmaster sessions found', got: %s", out)
	}
}

func TestList_ActiveSessions(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-abc", "my-project", "/home/user/code", "regular")
	createManifest(t, store, "qm-def", "other-work", "/home/user/other", "master")

	out := runCmd(t, store, sessionsRunner("qm-abc", "qm-def"), "list")
	if !strings.Contains(out, "Active:") {
		t.Fatalf("expected 'Active:' header, got: %s", out)
	}
	if !strings.Contains(out, "qm-abc") {
		t.Fatalf("expected qm-abc in output, got: %s", out)
	}
	if !strings.Contains(out, "my-project") {
		t.Fatalf("expected title in output, got: %s", out)
	}
	if !strings.Contains(out, "qm-def") {
		t.Fatalf("expected qm-def in output, got: %s", out)
	}
}

func TestList_StaleAndActive(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-live", "active", "/tmp/a", "regular")
	createManifest(t, store, "qm-stale", "stopped", "/tmp/b", "regular")

	out := runCmd(t, store, sessionsRunner("qm-live"), "list")
	if !strings.Contains(out, "Active:") {
		t.Fatalf("expected Active section, got: %s", out)
	}
	if !strings.Contains(out, "qm-live") {
		t.Fatalf("expected qm-live, got: %s", out)
	}
	if !strings.Contains(out, "Resumable") {
		t.Fatalf("expected Resumable section, got: %s", out)
	}
	if !strings.Contains(out, "qm-stale") {
		t.Fatalf("expected qm-stale in resumable, got: %s", out)
	}
}

func TestList_StaleOnly(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-old", "old-work", "/tmp/old", "regular")

	out := runCmd(t, store, sessionsRunner(), "list")
	if !strings.Contains(out, "Resumable") {
		t.Fatalf("expected Resumable section, got: %s", out)
	}
	if !strings.Contains(out, "qm-old") {
		t.Fatalf("expected qm-old, got: %s", out)
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
	zIdx := strings.Index(out, "qm-z")
	aIdx := strings.Index(out, "qm-a")
	mIdx := strings.Index(out, "qm-m")
	if zIdx < 0 || aIdx < 0 || mIdx < 0 {
		t.Fatalf("expected all sessions in output, got: %s", out)
	}
	if !(zIdx < aIdx && aIdx < mIdx) {
		t.Fatalf("expected tmux order (z, a, m), got: %s", out)
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
	if !strings.Contains(out, "qm-abc") {
		t.Fatalf("expected qm-abc, got: %s", out)
	}
	if !strings.Contains(out, "active") {
		t.Fatalf("expected 'active' status, got: %s", out)
	}
	if !strings.Contains(out, "my-project") {
		t.Fatalf("expected title, got: %s", out)
	}
	if !strings.Contains(out, "/home/user/code") {
		t.Fatalf("expected cwd, got: %s", out)
	}
}

func TestStatus_AcceptsQMIDs(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-abc", "my-project", "/home/user/code", "regular")

	out := runCmd(t, store, sessionsRunner("qm-abc"), "status", "qm-abc")
	if !strings.Contains(out, "qm-abc") {
		t.Fatalf("expected qm-abc, got: %s", out)
	}
	if !strings.Contains(out, "active") {
		t.Fatalf("expected 'active' status, got: %s", out)
	}
}

func TestStatus_StaleSession(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-old", "stale-project", "/tmp/old", "regular")

	out := runCmd(t, store, sessionsRunner(), "status", "qm-old")
	if !strings.Contains(out, "qm-old") {
		t.Fatalf("expected qm-old, got: %s", out)
	}
	if !strings.Contains(out, "stopped") {
		t.Fatalf("expected 'stopped' status, got: %s", out)
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
			wantLine := "Status:   " + tc.want + "\n"
			if !strings.Contains(out, wantLine) {
				t.Fatalf("expected %q in output, got:\n%s", wantLine, out)
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
	if !strings.Contains(out, "master") {
		t.Fatalf("expected 'master' type, got: %s", out)
	}
	if !strings.Contains(out, "qm-w1") {
		t.Fatalf("expected worker qm-w1, got: %s", out)
	}
	if !strings.Contains(out, "qm-w2") {
		t.Fatalf("expected worker qm-w2, got: %s", out)
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
	if !strings.Contains(out, "Pruned 1") {
		t.Fatalf("expected 'Pruned 1', got: %s", out)
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
	if strings.Contains(out, "Pruned") {
		t.Fatalf("should not prune master with workers, got: %s", out)
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
	if strings.Contains(out, "Pruned") {
		t.Fatalf("should not prune recent manifest, got: %s", out)
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
	if !strings.Contains(out, "Pruned 1") {
		t.Fatalf("expected 'Pruned 1', got: %s", out)
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
	if !strings.Contains(out, "qm-live") {
		t.Fatalf("expected session ID, got: %s", out)
	}
	if !strings.Contains(out, "active") {
		t.Fatalf("expected 'active' status, got: %s", out)
	}
	if !strings.Contains(out, "missing") {
		t.Fatalf("expected 'missing' manifest note, got: %s", out)
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
	if !strings.Contains(out, "active") {
		t.Fatalf("expected 'active' status, got: %s", out)
	}
	if !strings.Contains(out, "corrupt") {
		t.Fatalf("expected 'corrupt' manifest note, got: %s", out)
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
	if !strings.Contains(out, "Resumable") {
		t.Fatalf("expected Resumable section, got: %s", out)
	}
	// qm-k and qm-l should appear (newest) in the top 10
	if !strings.Contains(out, "qm-k") {
		t.Fatalf("expected qm-k (newest) in top 10, got: %s", out)
	}
	if !strings.Contains(out, "qm-l") {
		t.Fatalf("expected qm-l (newest) in top 10, got: %s", out)
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
	if !strings.Contains(out, "Pruned 1") {
		t.Fatalf("expected 'Pruned 1' for corrupt manifest, got: %s", out)
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
	if !strings.Contains(out, "No questmaster sessions found") {
		t.Fatalf("expected empty output, got: %s", out)
	}
	if _, err := os.Stat(dir); err == nil {
		t.Fatal("list should not have created the state directory")
	}
}

// ---------------------------------------------------------------------------
// Regression: status rejects non-party session IDs (Codex F2)
// ---------------------------------------------------------------------------

func TestStatus_NonPartySession_Rejected(t *testing.T) {
	t.Parallel()
	store := setupStore(t)

	_, err := runCmdErr(t, store, sessionsRunner("dev"), "status", "dev")
	if err == nil {
		t.Fatal("expected error for non-party session ID")
	}
}
