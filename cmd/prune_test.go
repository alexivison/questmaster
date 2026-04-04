//go:build linux || darwin

package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/anthropics/ai-party/tools/party-cli/internal/state"
	"github.com/anthropics/ai-party/tools/party-cli/internal/tmux"
)

func TestPruneOldEntries_Dirs(t *testing.T) {
	t.Parallel()

	root := t.TempDir()

	// Create old and new directories
	oldDir := filepath.Join(root, "old-project")
	if err := os.Mkdir(oldDir, 0o755); err != nil {
		t.Fatal(err)
	}
	// Set old mtime
	old := time.Now().Add(-60 * 24 * time.Hour)
	os.Chtimes(oldDir, old, old)

	newDir := filepath.Join(root, "new-project")
	if err := os.Mkdir(newDir, 0o755); err != nil {
		t.Fatal(err)
	}

	var buf bytes.Buffer
	count, err := pruneOldEntries(root, 30, true, false, &buf)
	if err != nil {
		t.Fatalf("pruneOldEntries: %v", err)
	}
	if count != 1 {
		t.Errorf("expected 1 pruned, got %d", count)
	}

	// old should be gone, new should remain
	if _, err := os.Stat(oldDir); !os.IsNotExist(err) {
		t.Error("old dir should be removed")
	}
	if _, err := os.Stat(newDir); err != nil {
		t.Error("new dir should remain")
	}
}

func TestPruneOldEntries_Files(t *testing.T) {
	t.Parallel()

	root := t.TempDir()

	oldFile := filepath.Join(root, "old.snap")
	if err := os.WriteFile(oldFile, []byte("data"), 0o644); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-90 * 24 * time.Hour)
	os.Chtimes(oldFile, old, old)

	newFile := filepath.Join(root, "new.snap")
	if err := os.WriteFile(newFile, []byte("data"), 0o644); err != nil {
		t.Fatal(err)
	}

	var buf bytes.Buffer
	count, err := pruneOldEntries(root, 60, false, false, &buf)
	if err != nil {
		t.Fatalf("pruneOldEntries: %v", err)
	}
	if count != 1 {
		t.Errorf("expected 1 pruned, got %d", count)
	}

	if _, err := os.Stat(oldFile); !os.IsNotExist(err) {
		t.Error("old file should be removed")
	}
	if _, err := os.Stat(newFile); err != nil {
		t.Error("new file should remain")
	}
}

func TestPruneOldEntries_DryRun(t *testing.T) {
	t.Parallel()

	root := t.TempDir()

	oldFile := filepath.Join(root, "old.snap")
	if err := os.WriteFile(oldFile, []byte("data"), 0o644); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-90 * 24 * time.Hour)
	os.Chtimes(oldFile, old, old)

	var buf bytes.Buffer
	count, err := pruneOldEntries(root, 60, false, true, &buf)
	if err != nil {
		t.Fatalf("pruneOldEntries: %v", err)
	}
	if count != 1 {
		t.Errorf("expected 1 counted, got %d", count)
	}

	// File should still exist in dry-run
	if _, err := os.Stat(oldFile); err != nil {
		t.Error("file should remain in dry-run mode")
	}
	if buf.Len() == 0 {
		t.Error("expected dry-run output")
	}
}

func TestPruneOldEntries_NonexistentDir(t *testing.T) {
	t.Parallel()

	count, err := pruneOldEntries("/nonexistent/path", 7, false, false, &bytes.Buffer{})
	if err != nil {
		t.Fatalf("expected nil error for nonexistent dir, got: %v", err)
	}
	if count != 0 {
		t.Errorf("expected 0, got %d", count)
	}
}

func TestPruneEmptyFiles(t *testing.T) {
	t.Parallel()

	root := t.TempDir()

	// Create empty file
	emptyFile := filepath.Join(root, "empty.log")
	if err := os.WriteFile(emptyFile, nil, 0o644); err != nil {
		t.Fatal(err)
	}

	// Create non-empty file
	nonEmpty := filepath.Join(root, "data.log")
	if err := os.WriteFile(nonEmpty, []byte("content"), 0o644); err != nil {
		t.Fatal(err)
	}

	var buf bytes.Buffer
	count, err := pruneEmptyFiles(root, false, &buf)
	if err != nil {
		t.Fatalf("pruneEmptyFiles: %v", err)
	}
	if count != 1 {
		t.Errorf("expected 1 pruned, got %d", count)
	}

	if _, err := os.Stat(emptyFile); !os.IsNotExist(err) {
		t.Error("empty file should be removed")
	}
	if _, err := os.Stat(nonEmpty); err != nil {
		t.Error("non-empty file should remain")
	}
}

func TestPruneEmptyFiles_DryRun(t *testing.T) {
	t.Parallel()

	root := t.TempDir()
	emptyFile := filepath.Join(root, "empty.log")
	if err := os.WriteFile(emptyFile, nil, 0o644); err != nil {
		t.Fatal(err)
	}

	var buf bytes.Buffer
	count, err := pruneEmptyFiles(root, true, &buf)
	if err != nil {
		t.Fatalf("pruneEmptyFiles: %v", err)
	}
	if count != 1 {
		t.Errorf("expected 1, got %d", count)
	}
	if _, err := os.Stat(emptyFile); err != nil {
		t.Error("file should remain in dry-run")
	}
}

func TestRunPruneArtifacts_NoHome(t *testing.T) {
	// Not parallel — t.Setenv
	t.Setenv("HOME", "")

	var buf bytes.Buffer
	err := runPruneArtifacts(&buf, 7, true)
	if err == nil {
		t.Fatal("expected error when HOME is empty")
	}
}

// ---------------------------------------------------------------------------
// Mock tmux runner for runPrune tests
// ---------------------------------------------------------------------------

type pruneRunner struct {
	sessions map[string]bool
}

func (r *pruneRunner) Run(_ context.Context, args ...string) (string, error) {
	if len(args) >= 1 && args[0] == "list-sessions" {
		var names []string
		for s := range r.sessions {
			names = append(names, s)
		}
		if len(names) == 0 {
			return "", &tmux.ExitError{Code: 1}
		}
		result := ""
		for i, s := range names {
			if i > 0 {
				result += "\n"
			}
			result += s
		}
		return result, nil
	}
	return "", &tmux.ExitError{Code: 1}
}

func writeManifestFile(t *testing.T, root, partyID string, data map[string]any, age time.Duration) {
	t.Helper()
	raw, err := json.Marshal(data)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	path := filepath.Join(root, partyID+".json")
	if err := os.WriteFile(path, raw, 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	past := time.Now().Add(-age)
	if err := os.Chtimes(path, past, past); err != nil {
		t.Fatalf("chtimes: %v", err)
	}
}

// ---------------------------------------------------------------------------
// runPrune deregistration test
// ---------------------------------------------------------------------------

func TestPrune_DeregistersFromParent(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	store, err := state.NewStore(root)
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	runner := &pruneRunner{sessions: map[string]bool{
		"party-master": true, // master is alive
	}}
	client := tmux.NewClient(runner)

	// Create master manifest (alive, won't be pruned) with worker in list
	masterData := map[string]any{
		"party_id":     "party-master",
		"cwd":          "/tmp",
		"session_type": "master",
		"workers":      []string{"party-old-worker"},
	}
	writeManifestFile(t, root, "party-master", masterData, 0)

	// Create old dead worker manifest referencing parent
	workerData := map[string]any{
		"party_id":       "party-old-worker",
		"cwd":            "/tmp",
		"parent_session": "party-master",
	}
	writeManifestFile(t, root, "party-old-worker", workerData, 10*24*time.Hour)

	var buf bytes.Buffer
	if err := runPrune(t.Context(), &buf, store, client, 7); err != nil {
		t.Fatalf("prune: %v", err)
	}

	// Worker manifest should be deleted
	if _, err := os.Stat(filepath.Join(root, "party-old-worker.json")); !os.IsNotExist(err) {
		t.Fatal("expected worker manifest to be pruned")
	}

	// Worker should be deregistered from master's Workers list
	m, err := store.Read("party-master")
	if err != nil {
		t.Fatalf("read master: %v", err)
	}
	for _, w := range m.Workers {
		if w == "party-old-worker" {
			t.Fatal("pruned worker should have been removed from master's Workers list")
		}
	}
}

func TestRunPrune_SkipsLiveSessionManifests(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	store, err := state.NewStore(root)
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	runner := &pruneRunner{sessions: map[string]bool{
		"party-alive": true,
	}}
	client := tmux.NewClient(runner)

	writeManifestFile(t, root, "party-alive", map[string]any{
		"party_id": "party-alive",
		"cwd":      "/tmp",
	}, 10*24*time.Hour)

	var buf bytes.Buffer
	if err := runPrune(t.Context(), &buf, store, client, 7); err != nil {
		t.Fatalf("prune: %v", err)
	}

	if _, err := os.Stat(filepath.Join(root, "party-alive.json")); err != nil {
		t.Fatal("live session manifest should not be pruned")
	}
}
