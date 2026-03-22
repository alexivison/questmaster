//go:build linux || darwin

package cmd

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
	"time"
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
