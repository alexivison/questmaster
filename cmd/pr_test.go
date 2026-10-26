package cmd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
)

func TestPRCommands(t *testing.T) {
	store := setupStore(t)
	t.Setenv(state.StateRootEnv, store.Root())
	t.Setenv(state.SessionEnv, "qm-pr")
	if err := store.Create(state.Manifest{SessionID: "qm-pr"}); err != nil {
		t.Fatal(err)
	}
	if err := store.Create(state.Manifest{SessionID: "qm-other"}); err != nil {
		t.Fatal(err)
	}
	var result struct {
		Key     string `json:"key"`
		Added   bool   `json:"added"`
		Removed bool   `json:"removed"`
	}
	if err := json.Unmarshal([]byte(runCmd(t, store, sessionsRunner(), "pr", "watch", "Owner/Repo#7")), &result); err != nil || !result.Added || result.Key != "github.com/owner/repo#7" {
		t.Fatalf("watch = %#v, %v", result, err)
	}
	if err := json.Unmarshal([]byte(runCmd(t, store, sessionsRunner(), "pr", "watch", "https://github.com/owner/repo/pull/7")), &result); err != nil || result.Added {
		t.Fatalf("repeat watch = %#v, %v", result, err)
	}
	var prs []state.PullRequest
	if err := json.Unmarshal([]byte(runCmd(t, store, sessionsRunner(), "pr", "ls")), &prs); err != nil || len(prs) != 1 || len(prs[0].Watchers) != 1 {
		t.Fatalf("ls = %#v, %v", prs, err)
	}
	if _, err := time.Parse(time.RFC3339Nano, prs[0].Watchers[0].AddedAt); err != nil {
		t.Fatal(err)
	}
	runCmd(t, store, sessionsRunner(), "pr", "watch", "other/repo#8", "--session", "qm-other")
	if err := json.Unmarshal([]byte(runCmd(t, store, sessionsRunner(), "pr", "ls", "--all")), &prs); err != nil || len(prs) != 2 {
		t.Fatalf("ls --all = %#v, %v", prs, err)
	}
	if err := json.Unmarshal([]byte(runCmd(t, store, sessionsRunner(), "pr", "unwatch", "owner/repo#7")), &result); err != nil || !result.Removed {
		t.Fatalf("unwatch = %#v, %v", result, err)
	}
	if got := runCmd(t, store, sessionsRunner(), "pr", "ls"); strings.TrimSpace(got) != "[]" {
		t.Fatalf("ls after unwatch = %q", got)
	}
}

func TestPRSessionRequiresManifest(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	for _, args := range [][]string{{"pr", "watch", "o/r#1", "--session", "qm-missing"}, {"pr", "unwatch", "o/r#1", "--session", "qm-missing"}, {"pr", "ls", "--session", "qm-missing"}} {
		cmd := NewRootCmd(WithDeps(store, tmux.NewClient(sessionsRunner())))
		cmd.SetArgs(args)
		if err := cmd.Execute(); err == nil || !strings.Contains(err.Error(), "live manifest") {
			t.Fatalf("%v: err = %v", args, err)
		}
	}
}

func TestPruneDropsOrphanWatchesAndDryRunPreservesRegistry(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	ref, _ := state.ParsePullRequestRef("owner/repo#1")
	if err := store.Create(state.Manifest{SessionID: "qm-orphan"}); err != nil {
		t.Fatal(err)
	}
	if _, err := state.WatchPullRequest(store.Root(), "qm-orphan", ref, time.Now()); err != nil {
		t.Fatal(err)
	}
	if err := store.Delete("qm-orphan"); err != nil {
		t.Fatal(err)
	}
	writeManifestFile(t, store.Root(), "qm-stale", map[string]any{"session_id": "qm-stale"}, 8*24*time.Hour)
	if _, err := state.WatchPullRequest(store.Root(), "qm-stale", ref, time.Now()); err != nil {
		t.Fatal(err)
	}
	path := state.PullRequestsRegistryPath(store.Root())
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	client := tmux.NewClient(&pruneRunner{sessions: map[string]bool{}})
	dry, err := pruneManifests(t.Context(), store, client, 7, true)
	if err != nil || dry.DroppedWatches != 2 {
		t.Fatalf("dry prune = %#v, %v", dry, err)
	}
	after, err := os.ReadFile(path)
	if err != nil || string(before) != string(after) {
		t.Fatalf("dry run changed registry: %v", err)
	}
	got, err := pruneManifests(t.Context(), store, client, 7, false)
	if err != nil || got.DroppedWatches != 2 {
		t.Fatalf("prune = %#v, %v", got, err)
	}
	prs, err := state.LoadPullRequests(store.Root())
	if err != nil || len(prs) != 0 {
		t.Fatalf("orphan retained: %#v, %v", prs, err)
	}
	if _, err := os.Stat(filepath.Join(store.Root(), "qm-orphan.json")); !os.IsNotExist(err) {
		t.Fatalf("unexpected manifest: %v", err)
	}
}
