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

	"github.com/anthropics/ai-config/tools/party-cli/internal/state"
	"github.com/anthropics/ai-config/tools/party-cli/internal/tmux"
	"github.com/anthropics/ai-config/tools/party-cli/internal/tui"
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

func createManifest(t *testing.T, store *state.Store, id, title, cwd, sessionType string) {
	t.Helper()
	m := state.Manifest{
		PartyID:     id,
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
		WithTUILauncher(func(...tui.Option) error { return nil }),
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
		WithTUILauncher(func(...tui.Option) error { return nil }),
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
	return &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) >= 1 && args[0] == "list-sessions" {
			if len(live) == 0 {
				return "", &tmux.ExitError{Code: 1}
			}
			return strings.Join(live, "\n"), nil
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

// ---------------------------------------------------------------------------
// list tests
// ---------------------------------------------------------------------------

func TestList_NoSessions(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	out := runCmd(t, store, sessionsRunner(), "list")
	if !strings.Contains(out, "No party sessions found") {
		t.Fatalf("expected 'No party sessions found', got: %s", out)
	}
}

func TestList_ActiveSessions(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "party-abc", "my-project", "/home/user/code", "regular")
	createManifest(t, store, "party-def", "other-work", "/home/user/other", "master")

	out := runCmd(t, store, sessionsRunner("party-abc", "party-def"), "list")
	if !strings.Contains(out, "Active:") {
		t.Fatalf("expected 'Active:' header, got: %s", out)
	}
	if !strings.Contains(out, "party-abc") {
		t.Fatalf("expected party-abc in output, got: %s", out)
	}
	if !strings.Contains(out, "my-project") {
		t.Fatalf("expected title in output, got: %s", out)
	}
	if !strings.Contains(out, "party-def") {
		t.Fatalf("expected party-def in output, got: %s", out)
	}
}

func TestList_StaleAndActive(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "party-live", "active", "/tmp/a", "regular")
	createManifest(t, store, "party-stale", "stopped", "/tmp/b", "regular")

	out := runCmd(t, store, sessionsRunner("party-live"), "list")
	if !strings.Contains(out, "Active:") {
		t.Fatalf("expected Active section, got: %s", out)
	}
	if !strings.Contains(out, "party-live") {
		t.Fatalf("expected party-live, got: %s", out)
	}
	if !strings.Contains(out, "Resumable") {
		t.Fatalf("expected Resumable section, got: %s", out)
	}
	if !strings.Contains(out, "party-stale") {
		t.Fatalf("expected party-stale in resumable, got: %s", out)
	}
}

func TestList_StaleOnly(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "party-old", "old-work", "/tmp/old", "regular")

	out := runCmd(t, store, sessionsRunner(), "list")
	if !strings.Contains(out, "Resumable") {
		t.Fatalf("expected Resumable section, got: %s", out)
	}
	if !strings.Contains(out, "party-old") {
		t.Fatalf("expected party-old, got: %s", out)
	}
}

func TestList_ActivePreservesTmuxOrder(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "party-z", "zulu", "/tmp/z", "regular")
	createManifest(t, store, "party-a", "alpha", "/tmp/a", "regular")
	createManifest(t, store, "party-m", "mike", "/tmp/m", "regular")

	// Tmux reports in z, a, m order
	out := runCmd(t, store, sessionsRunner("party-z", "party-a", "party-m"), "list")
	zIdx := strings.Index(out, "party-z")
	aIdx := strings.Index(out, "party-a")
	mIdx := strings.Index(out, "party-m")
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
	createManifest(t, store, "party-abc", "my-project", "/home/user/code", "regular")

	out := runCmd(t, store, sessionsRunner("party-abc"), "status", "party-abc")
	if !strings.Contains(out, "party-abc") {
		t.Fatalf("expected party-abc, got: %s", out)
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

func TestStatus_StaleSession(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "party-old", "stale-project", "/tmp/old", "regular")

	out := runCmd(t, store, sessionsRunner(), "status", "party-old")
	if !strings.Contains(out, "party-old") {
		t.Fatalf("expected party-old, got: %s", out)
	}
	if !strings.Contains(out, "stale") {
		t.Fatalf("expected 'stale' status, got: %s", out)
	}
}

func TestStatus_MissingManifest(t *testing.T) {
	t.Parallel()
	store := setupStore(t)

	_, err := runCmdErr(t, store, sessionsRunner(), "status", "party-ghost")
	if err == nil {
		t.Fatal("expected error for missing manifest")
	}
}

func TestStatus_MasterWithWorkers(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "party-master", "orchestrator", "/tmp/m", "master")
	if err := store.AddWorker("party-master", "party-w1"); err != nil {
		t.Fatal(err)
	}
	if err := store.AddWorker("party-master", "party-w2"); err != nil {
		t.Fatal(err)
	}

	out := runCmd(t, store, sessionsRunner("party-master"), "status", "party-master")
	if !strings.Contains(out, "master") {
		t.Fatalf("expected 'master' type, got: %s", out)
	}
	if !strings.Contains(out, "party-w1") {
		t.Fatalf("expected worker party-w1, got: %s", out)
	}
	if !strings.Contains(out, "party-w2") {
		t.Fatalf("expected worker party-w2, got: %s", out)
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
	createManifest(t, store, "party-stale", "old", "/tmp/old", "regular")
	ageManifest(t, store, "party-stale", 8)

	out := runCmd(t, store, sessionsRunner(), "prune")
	if !strings.Contains(out, "Pruned 1") {
		t.Fatalf("expected 'Pruned 1', got: %s", out)
	}
	if _, err := store.Read("party-stale"); err == nil {
		t.Fatal("expected manifest to be deleted")
	}
}

func TestPrune_SkipsLiveSessions(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "party-live", "active", "/tmp/a", "regular")
	ageManifest(t, store, "party-live", 8)

	out := runCmd(t, store, sessionsRunner("party-live"), "prune")
	if strings.Contains(out, "Pruned") {
		t.Fatalf("should not prune live session, got: %s", out)
	}
	if _, err := store.Read("party-live"); err != nil {
		t.Fatal("live manifest should still exist")
	}
}

func TestPrune_SkipsMasterWithWorkers(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "party-master", "orch", "/tmp/m", "master")
	if err := store.AddWorker("party-master", "party-w1"); err != nil {
		t.Fatal(err)
	}
	ageManifest(t, store, "party-master", 8)

	out := runCmd(t, store, sessionsRunner(), "prune")
	if strings.Contains(out, "Pruned") {
		t.Fatalf("should not prune master with workers, got: %s", out)
	}
	if _, err := store.Read("party-master"); err != nil {
		t.Fatal("master manifest should still exist")
	}
}

func TestPrune_KeepsRecentManifests(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "party-recent", "new", "/tmp/new", "regular")

	out := runCmd(t, store, sessionsRunner(), "prune")
	if strings.Contains(out, "Pruned") {
		t.Fatalf("should not prune recent manifest, got: %s", out)
	}
	if _, err := store.Read("party-recent"); err != nil {
		t.Fatal("recent manifest should still exist")
	}
}

func TestPrune_MixedStaleAndRecent(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "party-old", "old", "/tmp/old", "regular")
	createManifest(t, store, "party-new", "new", "/tmp/new", "regular")
	ageManifest(t, store, "party-old", 8)

	out := runCmd(t, store, sessionsRunner(), "prune")
	if !strings.Contains(out, "Pruned 1") {
		t.Fatalf("expected 'Pruned 1', got: %s", out)
	}
	if _, err := store.Read("party-old"); err == nil {
		t.Fatal("old manifest should be deleted")
	}
	if _, err := store.Read("party-new"); err != nil {
		t.Fatal("new manifest should still exist")
	}
}

// ---------------------------------------------------------------------------
// Regression: status on live session without manifest (F1)
// ---------------------------------------------------------------------------

func TestStatus_LiveSessionNoManifest(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	out := runCmd(t, store, sessionsRunner("party-live"), "status", "party-live")
	if !strings.Contains(out, "party-live") {
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
	corrupt := filepath.Join(store.Root(), "party-bad.json")
	if err := os.WriteFile(corrupt, []byte(`{invalid`), 0o644); err != nil {
		t.Fatalf("write corrupt: %v", err)
	}

	out := runCmd(t, store, sessionsRunner("party-bad"), "status", "party-bad")
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
		id := fmt.Sprintf("party-%c", 'a'+i)
		createManifest(t, store, id, "", "/tmp", "regular")
	}
	// Make party-k and party-l the newest (age 1 day), rest are older (age 3 days)
	for i := range 12 {
		id := fmt.Sprintf("party-%c", 'a'+i)
		if id == "party-k" || id == "party-l" {
			ageManifest(t, store, id, 1)
		} else {
			ageManifest(t, store, id, 3)
		}
	}

	out := runCmd(t, store, sessionsRunner(), "list")
	if !strings.Contains(out, "Resumable") {
		t.Fatalf("expected Resumable section, got: %s", out)
	}
	// party-k and party-l should appear (newest) in the top 10
	if !strings.Contains(out, "party-k") {
		t.Fatalf("expected party-k (newest) in top 10, got: %s", out)
	}
	if !strings.Contains(out, "party-l") {
		t.Fatalf("expected party-l (newest) in top 10, got: %s", out)
	}
}

// ---------------------------------------------------------------------------
// Regression: prune removes corrupt manifest files (F3)
// ---------------------------------------------------------------------------

func TestPrune_RemovesCorruptManifests(t *testing.T) {
	t.Parallel()
	store := setupStore(t)

	// Write a corrupt manifest file directly
	corrupt := filepath.Join(store.Root(), "party-corrupt.json")
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
	if !strings.Contains(out, "No party sessions found") {
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
