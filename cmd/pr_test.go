package cmd

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/daemon"
	"github.com/alexivison/questmaster/internal/prstatus"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
)

func TestPRCommands(t *testing.T) {
	stubPRDaemon(t)
	store := setupStore(t)
	t.Setenv("HOME", t.TempDir())
	t.Setenv("QUESTMASTER_BIN", filepath.Join(store.Root(), "canonical-qm"))
	ensureCalls, wakeCalls := 0, 0
	prEnsure = func(_ context.Context, config daemon.Config) (daemon.Record, error) {
		ensureCalls++
		if config.Root != store.Root() {
			t.Fatalf("daemon root=%s", config.Root)
		}
		if ensureCalls == 1 {
			prs, err := state.LoadPullRequests(store.Root())
			if err != nil || len(prs) != 0 {
				t.Fatalf("ensure happened after watch: %v %v", prs, err)
			}
		}
		return daemon.Record{}, fmt.Errorf("daemon unavailable")
	}
	prRequest = func(_ context.Context, _ daemon.Config, keys []string, wait bool) (map[string]prstatus.HostResult, error) {
		wakeCalls++
		if wait {
			t.Fatal("watch waited for GitHub")
		}
		prs, err := state.LoadPullRequests(store.Root())
		if err != nil || len(prs) == 0 {
			t.Fatalf("wake before registry write: %v %v", prs, err)
		}
		if len(keys) != 1 || keys[0] != "github.com/owner/repo#7" && keys[0] != "github.com/other/repo#8" {
			t.Fatalf("wake keys=%v", keys)
		}
		return map[string]prstatus.HostResult{}, nil
	}
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
	if ensureCalls != 2 || wakeCalls != 1 {
		t.Fatalf("ensure=%d wake=%d", ensureCalls, wakeCalls)
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

func TestPRDaemonConfigPrefersInstalledCanonicalOverDevShim(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	canonical := filepath.Join(home, "canonical-qm")
	if err := os.WriteFile(canonical, []byte("binary"), 0700); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(home, ".local", "bin", "questmaster")
	if err := os.MkdirAll(filepath.Dir(link), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(canonical, link); err != nil {
		t.Fatal(err)
	}
	t.Setenv("QUESTMASTER_BIN", filepath.Join(home, "dev-shim"))
	config := prDaemonConfig(t.TempDir())
	resolved, err := filepath.EvalSymlinks(canonical)
	if err != nil {
		t.Fatal(err)
	}
	if config.Executable != resolved {
		t.Fatalf("PR daemon executable=%s, want canonical %s", config.Executable, resolved)
	}
	id, err := daemon.Identity(config.Root, home, config.Executable)
	if err != nil || id != "canonical" {
		t.Fatalf("daemon identity=%s err=%v", id, err)
	}
	if err := os.Remove(link); err != nil {
		t.Fatal(err)
	}
	current, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	if got := prDaemonConfig(t.TempDir()).Executable; got != current {
		t.Fatalf("without installed link executable=%s, want current %s", got, current)
	}
}

func TestPRRefreshUsesWatchedScopeAndPersistsStatus(t *testing.T) {
	stubPRDaemon(t)
	t.Setenv("HOME", t.TempDir())
	var refreshed [][]string
	store := setupStore(t)
	t.Setenv(state.StateRootEnv, store.Root())
	t.Setenv(state.SessionEnv, "qm-pr")
	for _, id := range []string{"qm-pr", "qm-other"} {
		if err := store.Create(state.Manifest{SessionID: id}); err != nil {
			t.Fatal(err)
		}
	}
	if got := runCmd(t, store, sessionsRunner(), "pr", "refresh"); !strings.Contains(got, `"pull_requests": []`) {
		t.Fatalf("empty refresh = %s", got)
	}
	prRequest = func(_ context.Context, config daemon.Config, keys []string, wait bool) (map[string]prstatus.HostResult, error) {
		if !wait {
			return map[string]prstatus.HostResult{}, nil
		}
		refreshed = append(refreshed, append([]string(nil), keys...))
		updates := map[string]state.PullRequestStatus{}
		for _, key := range keys {
			updates[key] = state.PullRequestStatus{Title: "From fake daemon", State: "open", FetchedAt: time.Now().UTC().Format(time.RFC3339)}
		}
		if err := state.SavePullRequestStatuses(config.Root, updates, nil); err != nil {
			return nil, err
		}
		return map[string]prstatus.HostResult{"github.com": {RateLimit: &prstatus.RateLimit{Cost: 1}}}, nil
	}
	runCmd(t, store, sessionsRunner(), "pr", "watch", "o/r#1")
	runCmd(t, store, sessionsRunner(), "pr", "watch", "o/r#2", "--session", "qm-other")
	var result struct {
		PullRequests []state.PullRequest `json:"pull_requests"`
		Hosts        map[string]struct {
			RateLimit struct {
				Cost int `json:"cost"`
			} `json:"rate_limit"`
		} `json:"hosts"`
	}
	if err := json.Unmarshal([]byte(runCmd(t, store, sessionsRunner(), "pr", "refresh")), &result); err != nil {
		t.Fatal(err)
	}
	if len(result.PullRequests) != 1 || result.PullRequests[0].Status.Title != "From fake daemon" || result.Hosts["github.com"].RateLimit.Cost != 1 {
		t.Fatalf("refresh=%#v", result)
	}
	if err := json.Unmarshal([]byte(runCmd(t, store, sessionsRunner(), "pr", "refresh", "--all")), &result); err != nil {
		t.Fatal(err)
	}
	if len(result.PullRequests) != 2 {
		t.Fatalf("all=%#v", result.PullRequests)
	}
	if len(refreshed) != 2 || len(refreshed[0]) != 1 || len(refreshed[1]) != 2 {
		t.Fatalf("refresh scopes=%v", refreshed)
	}
	var listed []state.PullRequest
	if err := json.Unmarshal([]byte(runCmd(t, store, sessionsRunner(), "pr", "ls")), &listed); err != nil || len(listed) != 1 || listed[0].Status == nil {
		t.Fatalf("ls=%#v err=%v", listed, err)
	}
}

func TestPRRefreshFailsWithoutDaemon(t *testing.T) {
	stubPRDaemon(t)
	t.Setenv("HOME", t.TempDir())
	store := setupStore(t)
	t.Setenv(state.StateRootEnv, store.Root())
	t.Setenv(state.SessionEnv, "qm-pr")
	if err := store.Create(state.Manifest{SessionID: "qm-pr"}); err != nil {
		t.Fatal(err)
	}
	prEnsure = func(context.Context, daemon.Config) (daemon.Record, error) {
		return daemon.Record{}, fmt.Errorf("unreachable")
	}
	cmd := NewRootCmd(WithDeps(store, tmux.NewClient(sessionsRunner())))
	cmd.SetArgs([]string{"pr", "refresh"})
	if err := cmd.Execute(); err == nil || !strings.Contains(err.Error(), "running daemon") {
		t.Fatalf("error=%v", err)
	}
}

func stubPRDaemon(t *testing.T) {
	t.Helper()
	oldEnsure, oldRequest := prEnsure, prRequest
	prEnsure = func(context.Context, daemon.Config) (daemon.Record, error) { return daemon.Record{}, nil }
	prRequest = func(context.Context, daemon.Config, []string, bool) (map[string]prstatus.HostResult, error) {
		return map[string]prstatus.HostResult{}, nil
	}
	t.Cleanup(func() { prEnsure, prRequest = oldEnsure, oldRequest })
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
