//go:build linux || darwin

package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
)

func TestPruneHelpDoesNotMentionArtifacts(t *testing.T) {
	t.Parallel()

	cmd := newPruneCmd(nil, nil)
	var buf bytes.Buffer
	cmd.SetOut(&buf)
	cmd.SetErr(&buf)
	cmd.SetArgs([]string{"--help"})

	if err := cmd.Execute(); err != nil {
		t.Fatalf("help: %v", err)
	}

	if cmd.Flags().Lookup("artifacts") != nil {
		t.Fatal("artifacts flag should not be registered")
	}

	out := buf.String()
	if strings.Contains(out, "--artifacts") || strings.Contains(out, "artifacts") {
		t.Fatalf("help should not mention artifacts, got:\n%s", out)
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

func writeManifestFile(t *testing.T, root, sessionID string, data map[string]any, age time.Duration) {
	t.Helper()
	raw, err := json.Marshal(data)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	path := filepath.Join(root, sessionID+".json")
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
		"qm-master": true, // master is alive
	}}
	client := tmux.NewClient(runner)

	// Create master manifest (alive, won't be pruned) with worker in list
	masterData := map[string]any{
		"session_id":     "qm-master",
		"cwd":          "/tmp",
		"session_type": "master",
		"workers":      []string{"qm-old-worker"},
	}
	writeManifestFile(t, root, "qm-master", masterData, 0)

	// Create old dead worker manifest referencing parent
	workerData := map[string]any{
		"session_id":       "qm-old-worker",
		"cwd":            "/tmp",
		"parent_session": "qm-master",
	}
	writeManifestFile(t, root, "qm-old-worker", workerData, 10*24*time.Hour)

	var buf bytes.Buffer
	if err := runPrune(t.Context(), &buf, store, client, 7, false); err != nil {
		t.Fatalf("prune: %v", err)
	}

	// Worker manifest should be deleted
	if _, err := os.Stat(filepath.Join(root, "qm-old-worker.json")); !os.IsNotExist(err) {
		t.Fatal("expected worker manifest to be pruned")
	}

	// Worker should be deregistered from master's Workers list
	m, err := store.Read("qm-master")
	if err != nil {
		t.Fatalf("read master: %v", err)
	}
	for _, w := range m.Workers {
		if w == "qm-old-worker" {
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
		"qm-alive": true,
	}}
	client := tmux.NewClient(runner)

	writeManifestFile(t, root, "qm-alive", map[string]any{
		"session_id": "qm-alive",
		"cwd":      "/tmp",
	}, 10*24*time.Hour)

	var buf bytes.Buffer
	if err := runPrune(t.Context(), &buf, store, client, 7, false); err != nil {
		t.Fatalf("prune: %v", err)
	}

	if _, err := os.Stat(filepath.Join(root, "qm-alive.json")); err != nil {
		t.Fatal("live session manifest should not be pruned")
	}
}

func TestRunPrune_DryRunPreviewsManifestAndPreservesState(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	store, err := state.NewStore(root)
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	runner := &pruneRunner{sessions: map[string]bool{
		"qm-master": true,
	}}
	client := tmux.NewClient(runner)

	masterData := map[string]any{
		"session_id":     "qm-master",
		"cwd":          "/tmp",
		"session_type": "master",
		"workers":      []string{"qm-old-worker"},
	}
	writeManifestFile(t, root, "qm-master", masterData, 0)

	workerData := map[string]any{
		"session_id":       "qm-old-worker",
		"cwd":            "/tmp",
		"parent_session": "qm-master",
	}
	writeManifestFile(t, root, "qm-old-worker", workerData, 10*24*time.Hour)

	var buf bytes.Buffer
	if err := runPrune(t.Context(), &buf, store, client, 7, true); err != nil {
		t.Fatalf("prune: %v", err)
	}

	workerPath := filepath.Join(root, "qm-old-worker.json")
	if _, err := os.Stat(workerPath); err != nil {
		t.Fatal("dry-run should not delete stale worker manifest")
	}

	m, err := store.Read("qm-master")
	if err != nil {
		t.Fatalf("read master: %v", err)
	}
	found := false
	for _, w := range m.Workers {
		if w == "qm-old-worker" {
			found = true
			break
		}
	}
	if !found {
		t.Fatal("dry-run should not deregister the worker from its parent manifest")
	}

	out := buf.String()
	if !strings.Contains(out, "  [dry-run] rm "+workerPath) {
		t.Fatalf("expected dry-run preview for manifest, got: %s", out)
	}
	if !strings.Contains(out, "Would prune 1 session manifest(s) older than 7 days.") {
		t.Fatalf("expected dry-run summary, got: %s", out)
	}
}
