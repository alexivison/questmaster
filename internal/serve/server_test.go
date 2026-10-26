//go:build linux || darwin

package serve

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/modelsuggest"
	"github.com/alexivison/questmaster/internal/sessionactivity"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tracker"
	"github.com/fsnotify/fsnotify"
)

type fakeTmuxRunner struct {
	sessions string
	err      error
}

func (r fakeTmuxRunner) Run(context.Context, ...string) (string, error) {
	return r.sessions, r.err
}

type countingTmuxRunner struct {
	mu       sync.Mutex
	sessions string
	counts   map[string]int
}

func (r *countingTmuxRunner) Run(_ context.Context, args ...string) (string, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.counts == nil {
		r.counts = map[string]int{}
	}
	if len(args) > 0 {
		r.counts[args[0]]++
	}
	return r.sessions, nil
}

func (r *countingTmuxRunner) Count(command string) int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.counts[command]
}

type manualChangeSource struct {
	ch chan Change
}

func newManualChangeSource() *manualChangeSource {
	return &manualChangeSource{ch: make(chan Change, 16)}
}

func (s *manualChangeSource) Subscribe(ctx context.Context) (<-chan Change, func()) {
	go func() { <-ctx.Done() }()
	return s.ch, func() {}
}

func (s *manualChangeSource) Close() error { return nil }

func (s *manualChangeSource) Publish(change Change) {
	s.ch <- change
}

func TestSnapshotterSurfacesTracker(t *testing.T) {
	env := seedServeFixture(t)
	snap := NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return env.now })

	got, err := snap.TrackerForChange(Change{})
	if err != nil {
		t.Fatalf("Tracker: %v", err)
	}
	if got.Current == nil || got.Current.ID != "qm-demo" {
		t.Fatalf("tracker current = %#v, want qm-demo", got.Current)
	}
	if len(got.Sessions) != 1 {
		t.Fatalf("tracker sessions = %d, want 1", len(got.Sessions))
	}
	row := got.Sessions[0]
	if row.Status != "active" || row.State != "working" || row.LatestActivity != "Bash: go test ./..." {
		t.Fatalf("tracker row = %#v, want active working with latest activity", row)
	}
	if row.WorktreePath != env.worktree {
		t.Fatalf("worktree = %q, want %q", row.WorktreePath, env.worktree)
	}
}

func TestSnapshotterBackfillsMasterClassesOnce(t *testing.T) {
	env := seedServeFixture(t)
	ids := []string{"qm-demo", "qm-backfill-a", "qm-backfill-b"}
	for _, id := range ids[1:] {
		if err := env.store.Create(state.Manifest{
			SessionID: id,
			Cwd:       env.worktree,
			Agents:    []state.AgentManifest{{Name: "codex", Role: "primary"}},
		}); err != nil {
			t.Fatalf("create master %s: %v", id, err)
		}
	}
	tmuxClient := tmux.NewClient(fakeTmuxRunner{sessions: strings.Join(ids, "\n")})
	snapshotter := NewSnapshotter(env.store, tmuxClient, func() time.Time { return env.now })
	snapshotter.randomIndex = func(int) int { return 0 }

	first, err := snapshotter.TrackerForChange(Change{})
	if err != nil {
		t.Fatalf("first tracker snapshot: %v", err)
	}
	classes := make(map[string]bool, len(ids))
	manifestBytes := make(map[string][]byte, len(ids))
	for _, row := range first.Sessions {
		if !slices.Contains(ids, row.ID) {
			continue
		}
		classes[row.Class] = true
		manifest, err := env.store.Read(row.ID)
		if err != nil {
			t.Fatalf("read manifest %s: %v", row.ID, err)
		}
		if manifest.DisplayClass() != row.Class || row.Class == "" {
			t.Fatalf("row %s class = %q manifest class = %q", row.ID, row.Class, manifest.DisplayClass())
		}
		manifestBytes[row.ID], err = os.ReadFile(filepath.Join(env.store.Root(), row.ID+".json"))
		if err != nil {
			t.Fatalf("read manifest bytes %s: %v", row.ID, err)
		}
	}
	if len(classes) != len(ids) {
		t.Fatalf("backfilled classes = %v, want %d balanced classes", classes, len(ids))
	}

	second, err := snapshotter.TrackerForChange(Change{BroadTracker: true})
	if err != nil {
		t.Fatalf("second tracker snapshot: %v", err)
	}
	for _, row := range second.Sessions {
		if _, ok := manifestBytes[row.ID]; !ok {
			continue
		}
		if !classes[row.Class] {
			t.Fatalf("row %s class changed from backfilled set: %q", row.ID, row.Class)
		}
		got, err := os.ReadFile(filepath.Join(env.store.Root(), row.ID+".json"))
		if err != nil {
			t.Fatalf("read manifest bytes %s: %v", row.ID, err)
		}
		if !bytes.Equal(got, manifestBytes[row.ID]) {
			t.Fatalf("manifest %s changed on the second snapshot", row.ID)
		}
	}
}

func TestSnapshotterKeepsTrackerWhenClassBackfillFails(t *testing.T) {
	env := seedServeFixture(t)
	manifestPath := filepath.Join(env.store.Root(), "qm-demo.json")
	if err := os.Mkdir(manifestPath+".tmp", 0o700); err != nil {
		t.Fatalf("block manifest temp path: %v", err)
	}
	defer os.RemoveAll(manifestPath + ".tmp")
	snapshotter := NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return env.now })
	snapshotter.randomIndex = func(int) int { return 0 }
	snapshotter.fetcher = func(tracker.SessionInfo) (tracker.TrackerSnapshot, error) {
		return tracker.TrackerSnapshot{
			LivenessKnown: true,
			Sessions: []tracker.SessionRow{{
				ID: "qm-demo", SessionType: "master", Status: "stopped",
			}},
		}, nil
	}

	got, err := snapshotter.TrackerForChange(Change{})
	if err != nil {
		t.Fatalf("tracker snapshot after failed backfill: %v", err)
	}
	if len(got.Sessions) != 1 || got.Sessions[0].Class != "" {
		t.Fatalf("tracker sessions = %#v, want one unclassified row", got.Sessions)
	}
	manifest, err := env.store.Read("qm-demo")
	if err != nil {
		t.Fatalf("read manifest after failed write: %v", err)
	}
	if manifest.DisplayClass() != "" {
		t.Fatalf("persisted class = %q after failed write, want none", manifest.DisplayClass())
	}
}

func TestSnapshotterSkipsClassBackfillWhenTmuxLivenessIsUnknown(t *testing.T) {
	env := seedServeFixture(t)
	tmuxClient := tmux.NewClient(fakeTmuxRunner{err: &tmux.ExitError{
		Code: 1, Stderr: "error connecting to /tmp/tmux-1000/default: Permission denied",
	}})
	snapshotter := NewSnapshotter(env.store, tmuxClient, func() time.Time { return env.now })
	snapshotter.randomIndex = func(int) int { return 0 }

	got, err := snapshotter.TrackerForChange(Change{})
	if err != nil {
		t.Fatalf("tracker snapshot with unknown liveness: %v", err)
	}
	if len(got.Sessions) != 1 || got.Sessions[0].Class != "" {
		t.Fatalf("tracker sessions = %#v, want one unclassified row", got.Sessions)
	}
	manifest, err := env.store.Read("qm-demo")
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}
	if manifest.DisplayClass() != "" {
		t.Fatalf("persisted class = %q, want none while liveness is unknown", manifest.DisplayClass())
	}
}

func TestSnapshotterWorkersFollowMasterReclass(t *testing.T) {
	env := seedServeFixture(t)
	if err := env.store.SetSessionClass("qm-demo", "wizard"); err != nil {
		t.Fatalf("set master class: %v", err)
	}
	if err := env.store.Create(state.Manifest{
		SessionID: "qm-worker",
		Cwd:       env.worktree,
		Agents:    []state.AgentManifest{{Name: "codex", Role: "primary"}},
		Display:   &state.DisplayMetadata{Class: "barbarian"},
		Extra:     map[string]json.RawMessage{"parent_session": json.RawMessage(`"qm-demo"`)},
	}); err != nil {
		t.Fatalf("create worker: %v", err)
	}
	snapshotter := NewSnapshotter(env.store, tmux.NewClient(fakeTmuxRunner{sessions: "qm-demo\nqm-worker"}), func() time.Time { return env.now })
	classFor := func(snapshot TrackerSnapshot) string {
		for _, row := range snapshot.Sessions {
			if row.ID == "qm-worker" {
				return row.Class
			}
		}
		return ""
	}

	first, err := snapshotter.TrackerForChange(Change{})
	if err != nil {
		t.Fatalf("first tracker snapshot: %v", err)
	}
	if got := classFor(first); got != "wizard" {
		t.Fatalf("worker class = %q, want master's wizard class", got)
	}

	if err := env.store.SetSessionClass("qm-demo", "bard"); err != nil {
		t.Fatalf("reclass master: %v", err)
	}
	second, err := snapshotter.TrackerForChange(Change{BroadTracker: true})
	if err != nil {
		t.Fatalf("second tracker snapshot: %v", err)
	}
	if got := classFor(second); got != "bard" {
		t.Fatalf("worker class after master reclass = %q, want bard", got)
	}
}

func TestSnapshotterTrackerSessionChangeProjectsArtifacts(t *testing.T) {
	env := seedServeFixture(t)
	snap := NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return env.now })
	if _, err := snap.TrackerForChange(Change{}); err != nil {
		t.Fatalf("initial Tracker: %v", err)
	}

	planPath := filepath.Join(env.worktree, "docs", "plan.html")
	if err := os.MkdirAll(filepath.Dir(planPath), 0o755); err != nil {
		t.Fatalf("mkdir artifact dir: %v", err)
	}
	if err := os.WriteFile(planPath, []byte("<h1>Plan</h1>"), 0o644); err != nil {
		t.Fatalf("write artifact: %v", err)
	}
	missingPath := filepath.Join(env.worktree, "docs", "missing.html")
	if err := state.UpsertArtifact("qm-demo", state.Artifact{
		Kind:    "html",
		Path:    planPath,
		Label:   "Plan",
		AddedAt: "2026-06-19T04:19:00Z",
	}); err != nil {
		t.Fatalf("upsert plan artifact: %v", err)
	}
	if err := state.UpsertArtifact("qm-demo", state.Artifact{
		Kind:    "html",
		Path:    missingPath,
		AddedAt: "2026-06-19T04:21:00Z",
	}); err != nil {
		t.Fatalf("upsert missing artifact: %v", err)
	}
	if err := state.SaveSessionState("qm-demo", &state.SessionState{
		SessionID: "qm-demo",
		Version:   state.SchemaVersion,
		Panes:     map[string]state.PaneState{"agent": {Role: "agent", State: "working"}},
	}); err != nil {
		t.Fatalf("old hook rewrite: %v", err)
	}

	tracker, err := snap.TrackerForChange(Change{Topics: []string{topicTracker}, BroadTracker: true})
	if err != nil {
		t.Fatalf("TrackerForChange: %v", err)
	}
	artifacts := tracker.Sessions[0].Artifacts
	if len(artifacts) != 2 {
		t.Fatalf("artifacts = %#v, want two", artifacts)
	}
	if artifacts[0].Path != missingPath || artifacts[0].Label != "missing.html" || !artifacts[0].Missing {
		t.Fatalf("newest missing artifact = %#v", artifacts[0])
	}
	if artifacts[1].Path != planPath || artifacts[1].Label != "Plan" || artifacts[1].Missing {
		t.Fatalf("existing artifact = %#v", artifacts[1])
	}
	if len(tracker.Artifacts) != 2 {
		t.Fatalf("top-level artifacts = %#v, want two", tracker.Artifacts)
	}
	if tracker.Artifacts[0].SessionID != "qm-demo" || tracker.Artifacts[0].Path != missingPath {
		t.Fatalf("top-level newest artifact = %#v, want session-owned missing artifact", tracker.Artifacts[0])
	}
}

func TestSnapshotterIncludesQuests(t *testing.T) {
	env := seedServeFixture(t)
	if _, err := state.UpsertQuestAt(env.store.Root(), state.Quest{
		ID:          "qst-serve",
		Content:     "Wire quests into serve",
		ProjectID:   "repo",
		ProjectPath: env.worktree,
		ProjectName: "questmaster",
		SessionID:   "qm-demo",
	}); err != nil {
		t.Fatalf("upsert quest: %v", err)
	}

	tracker, err := NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return env.now }).TrackerForChange(Change{})
	if err != nil {
		t.Fatalf("TrackerForChange: %v", err)
	}
	if len(tracker.Quests) != 1 || tracker.Quests[0].ID != "qst-serve" || tracker.Quests[0].ProjectPath != env.worktree {
		t.Fatalf("quests = %#v, want qst-serve", tracker.Quests)
	}
}

func TestSnapshotterProjectsCollapseHistoricalWorktrees(t *testing.T) {
	root := filepath.Join(t.TempDir(), "state")
	t.Setenv(state.StateRootEnv, root)
	t.Setenv("QUESTMASTER_SESSION", "")

	store, err := state.NewStore(root)
	if err != nil {
		t.Fatalf("state store: %v", err)
	}
	repoRoot := filepath.Join(t.TempDir(), "questmaster")
	worktree := filepath.Join(t.TempDir(), "questmaster-worktree")
	gitDir := filepath.Join(repoRoot, ".git")
	worktreeGitDir := filepath.Join(gitDir, "worktrees", "questmaster-worktree")
	for _, dir := range []string{gitDir, worktree, worktreeGitDir} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatalf("mkdir %s: %v", dir, err)
		}
	}
	if err := os.WriteFile(filepath.Join(worktree, ".git"), []byte("gitdir: "+worktreeGitDir+"\n"), 0o644); err != nil {
		t.Fatalf("write worktree git file: %v", err)
	}
	if err := os.WriteFile(filepath.Join(worktreeGitDir, "commondir"), []byte("../..\n"), 0o644); err != nil {
		t.Fatalf("write commondir: %v", err)
	}
	for _, manifest := range []state.Manifest{
		{SessionID: "qm-main", Cwd: repoRoot, Title: "main"},
		{SessionID: "qm-worktree", Cwd: worktree, Title: "worktree"},
	} {
		if err := store.Create(manifest); err != nil {
			t.Fatalf("create manifest %s: %v", manifest.SessionID, err)
		}
	}
	projectID, err := filepath.EvalSymlinks(gitDir)
	if err != nil {
		t.Fatalf("resolve git dir: %v", err)
	}
	projectPath := filepath.Dir(projectID)
	if err := state.NewRepoColorStore(root).Set(projectID, "green"); err != nil {
		t.Fatalf("set repo color: %v", err)
	}

	tracker, err := NewSnapshotter(store, tmux.NewClient(fakeTmuxRunner{}), time.Now).TrackerForChange(Change{})
	if err != nil {
		t.Fatalf("TrackerForChange: %v", err)
	}
	if len(tracker.Projects) != 1 {
		t.Fatalf("projects = %#v, want one collapsed project", tracker.Projects)
	}
	project := tracker.Projects[0]
	if project.ID != projectID || project.Path != projectPath || project.Name != "questmaster" || project.Color != "green" {
		t.Fatalf("project = %#v, want id %q path %q name questmaster color green", project, projectID, projectPath)
	}
}

func TestSnapshotterProjectsUseDurableRepoSourcesWithoutManifests(t *testing.T) {
	root := filepath.Join(t.TempDir(), "state")
	t.Setenv(state.StateRootEnv, root)
	t.Setenv("QUESTMASTER_SESSION", "")

	store, err := state.NewStore(root)
	if err != nil {
		t.Fatalf("state store: %v", err)
	}
	colorRoot, colorID := makeTestRepo(t, "dotfiles")
	artifactRoot, artifactID := makeTestRepo(t, "legalon-next")
	questRoot, questID := makeTestRepo(t, "scry")
	if err := state.NewRepoColorStore(root).Set(colorID, "green"); err != nil {
		t.Fatalf("set repo color: %v", err)
	}
	if err := state.UpsertArtifactGlobal(root, state.Artifact{
		Kind:      "html",
		Path:      filepath.Join(artifactRoot, "plan.html"),
		ProjectID: artifactID,
		AddedAt:   "2026-07-03T05:00:00Z",
	}); err != nil {
		t.Fatalf("upsert repo artifact: %v", err)
	}
	if err := state.UpsertArtifactGlobal(root, state.Artifact{
		Kind:      "html",
		Path:      filepath.Join(colorRoot, "weekly.html"),
		ProjectID: "_weekly",
		AddedAt:   "2026-07-03T05:01:00Z",
	}); err != nil {
		t.Fatalf("upsert bucket artifact: %v", err)
	}
	if _, err := state.UpsertQuestAt(root, state.Quest{
		ID:          "qst-repo",
		Content:     "Repo quest",
		ProjectID:   questID,
		ProjectPath: questRoot,
		ProjectName: "scry",
	}); err != nil {
		t.Fatalf("upsert repo quest: %v", err)
	}
	if _, err := state.UpsertQuestAt(root, state.Quest{
		ID:        "qst-bucket",
		Content:   "Bucket quest",
		ProjectID: "_migration",
	}); err != nil {
		t.Fatalf("upsert bucket quest: %v", err)
	}

	tracker, err := NewSnapshotter(store, tmux.NewClient(fakeTmuxRunner{}), time.Now).TrackerForChange(Change{})
	if err != nil {
		t.Fatalf("TrackerForChange: %v", err)
	}
	got := map[string]ProjectSnapshot{}
	for _, project := range tracker.Projects {
		got[project.ID] = project
		if strings.HasPrefix(project.ID, "_") {
			t.Fatalf("projects included pseudo bucket: %#v", tracker.Projects)
		}
	}
	for _, id := range []string{colorID, artifactID, questID} {
		if _, ok := got[id]; !ok {
			t.Fatalf("project %q missing from %#v", id, tracker.Projects)
		}
	}
	if got[colorID].Color != "green" {
		t.Fatalf("repo color project = %#v, want green", got[colorID])
	}
	if len(got) != 3 {
		t.Fatalf("projects = %#v, want only durable real repos", tracker.Projects)
	}
}

func TestSnapshotterSessionChangeRefreshesArtifactsFromRegistry(t *testing.T) {
	env := seedServeFixture(t)
	snap := NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return env.now })
	if _, err := snap.TrackerForChange(Change{}); err != nil {
		t.Fatalf("initial Tracker: %v", err)
	}

	path := filepath.Join(env.worktree, "docs", "plan.html")
	if err := state.UpsertArtifact("qm-demo", state.Artifact{
		Kind:    "html",
		Path:    path,
		Label:   "Plan",
		AddedAt: "2026-06-19T04:21:00Z",
	}); err != nil {
		t.Fatalf("upsert artifact: %v", err)
	}
	if err := state.UpdateSessionState("qm-demo", func(ss *state.SessionState) bool {
		pane := ss.Panes["agent"]
		pane.Activity = "UserPromptSubmit"
		ss.Panes["agent"] = pane
		return true
	}); err != nil {
		t.Fatalf("message state update: %v", err)
	}

	tracker, err := snap.TrackerForChange(Change{Topics: []string{topicTracker}, SessionIDs: []string{"qm-demo"}})
	if err != nil {
		t.Fatalf("TrackerForChange: %v", err)
	}
	if len(tracker.Artifacts) != 1 || tracker.Artifacts[0].Path != path {
		t.Fatalf("top-level artifacts = %#v, want registry artifact", tracker.Artifacts)
	}
	if len(tracker.Sessions[0].Artifacts) != 1 || tracker.Sessions[0].Artifacts[0].Path != path {
		t.Fatalf("session artifacts = %#v, want registry artifact", tracker.Sessions[0].Artifacts)
	}
}

func TestServerSocketReadsAndPushesTrackerUpdates(t *testing.T) {
	env := seedServeFixture(t)
	socketPath := tempSocketPath(t)
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()

	srv := &Server{
		SocketPath:    socketPath,
		Snapshotter:   NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return env.now }),
		ClockInterval: time.Hour,
	}
	errc := serveInBackground(t, ctx, srv, socketPath)

	conn, enc, dec := dialServe(t, socketPath)
	defer conn.Close() //nolint:errcheck
	writeRequest(t, enc, map[string]any{"id": "1", "method": "tracker"})
	assertResponseTopic(t, dec, "tracker")
	writeRequest(t, enc, map[string]any{
		"id":     "sub",
		"method": "subscribe",
		"topics": []string{"tracker"},
	})
	assertResponseTopic(t, dec, "subscribe")
	assertEventTopic(t, dec, "tracker")

	updateSessionActivity(t, env.now)
	seen := readEventsUntil(t, conn, dec, 2*time.Second, func(env Envelope, seen map[string]bool) bool {
		return env.Type == "event" && env.Topic == "tracker" && envelopeContains(env, "Question: approve?")
	})
	if !seen["tracker"] {
		t.Fatalf("file-watch events = %v, want tracker", seen)
	}

	cancel()
	if err := <-errc; err != nil {
		t.Fatalf("server returned error: %v", err)
	}
}

func TestServerSocketRestrictsOwnerAccess(t *testing.T) {
	env := seedServeFixture(t)
	socketDir := filepath.Join("/tmp", fmt.Sprintf("qm-serve-mode-%d", time.Now().UnixNano()))
	t.Cleanup(func() { os.RemoveAll(socketDir) }) //nolint:errcheck
	socketPath := filepath.Join(socketDir, "serve.sock")
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()

	srv := &Server{
		SocketPath:    socketPath,
		Snapshotter:   NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return env.now }),
		ClockInterval: time.Hour,
	}
	errc := serveInBackground(t, ctx, srv, socketPath)

	dirInfo, err := os.Stat(socketDir)
	if err != nil {
		t.Fatalf("stat socket dir: %v", err)
	}
	if got := dirInfo.Mode().Perm(); got != 0o700 {
		t.Fatalf("socket dir mode = %03o, want 700", got)
	}
	socketInfo, err := os.Stat(socketPath)
	if err != nil {
		t.Fatalf("stat socket: %v", err)
	}
	if got := socketInfo.Mode().Perm(); got != 0o600 {
		t.Fatalf("socket mode = %03o, want 600", got)
	}

	cancel()
	if err := <-errc; err != nil {
		t.Fatalf("server returned error: %v", err)
	}
}

func TestSnapshotterTrackerCachesTmuxListSessions(t *testing.T) {
	env := seedServeFixture(t)
	runner := &countingTmuxRunner{sessions: "qm-demo"}
	snap := NewSnapshotter(env.store, tmux.NewClient(runner), func() time.Time { return env.now })

	if _, err := snap.TrackerForChange(Change{}); err != nil {
		t.Fatalf("first Tracker: %v", err)
	}
	if _, err := snap.TrackerForChange(Change{}); err != nil {
		t.Fatalf("second Tracker: %v", err)
	}
	if got := runner.Count("list-sessions"); got != 1 {
		t.Fatalf("list-sessions calls = %d, want cached single call", got)
	}
	snap.Invalidate(Change{Topics: []string{topicTracker}, SessionIDs: []string{"qm-demo"}})
	if _, err := snap.TrackerForChange(Change{}); err != nil {
		t.Fatalf("Tracker after invalidate: %v", err)
	}
	if got := runner.Count("list-sessions"); got != 1 {
		t.Fatalf("list-sessions calls after state invalidate = %d, want cached single call", got)
	}
	lifecycle := mergeChanges(
		Change{Topics: []string{topicTracker}, SessionIDs: []string{"qm-demo"}, Lifecycle: true},
		Change{Topics: []string{topicTracker}, SessionIDs: []string{"qm-demo"}},
	)
	if !lifecycle.Lifecycle {
		t.Fatalf("merged lifecycle change lost its lifecycle flag: %#v", lifecycle)
	}
	snap.Invalidate(lifecycle)
	if _, err := snap.TrackerForChange(Change{}); err != nil {
		t.Fatalf("Tracker after lifecycle invalidate: %v", err)
	}
	if got := runner.Count("list-sessions"); got != 2 {
		t.Fatalf("list-sessions calls after lifecycle invalidate = %d, want 2", got)
	}
}

func TestSnapshotterTrackerIncrementalSessionChangeReusesCachedSnapshot(t *testing.T) {
	env := seedServeFixture(t)
	snap := NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return env.now })
	fetches := 0
	snap.fetcher = func(tracker.SessionInfo) (tracker.TrackerSnapshot, error) {
		fetches++
		return tracker.TrackerSnapshot{
			ObservedAt: env.now,
			Sessions: []tracker.SessionRow{{
				ID:          "qm-demo",
				Title:       "Serve runtime JSON",
				Status:      "active",
				SessionType: "master",
				Agent:       "codex",
			}},
		}, nil
	}

	if _, err := snap.TrackerForChange(Change{}); err != nil {
		t.Fatalf("initial Tracker: %v", err)
	}
	updateSessionActivity(t, env.now)
	got, err := snap.TrackerForChange(Change{Topics: []string{topicTracker}, SessionIDs: []string{"qm-demo"}})
	if err != nil {
		t.Fatalf("incremental Tracker: %v", err)
	}
	if fetches != 1 {
		t.Fatalf("full tracker fetches = %d, want only initial fetch", fetches)
	}
	if got.Sessions[0].State != "blocked" || got.Sessions[0].LatestActivity != "Question: approve?" {
		t.Fatalf("incremental tracker row = %#v, want blocked Question activity", got.Sessions)
	}
}

func TestSnapshotterManifestChangeRefreshesAgentAndRepo(t *testing.T) {
	env := seedServeFixture(t)
	if err := env.store.Update("qm-demo", func(m *state.Manifest) {
		m.Title = "probe"
		m.Cwd = "/tmp"
		m.Agents = nil
	}); err != nil {
		t.Fatalf("seed shell manifest: %v", err)
	}
	snap := NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return env.now })
	initial, err := snap.TrackerForChange(Change{})
	if err != nil {
		t.Fatalf("initial Tracker: %v", err)
	}
	if initial.Sessions[0].Agent != "" {
		t.Fatalf("initial agent = %q, want empty shell row", initial.Sessions[0].Agent)
	}

	repoRoot := filepath.Join(t.TempDir(), "adopted")
	if err := os.MkdirAll(filepath.Join(repoRoot, ".git"), 0o755); err != nil {
		t.Fatalf("create adopted repo: %v", err)
	}
	if err := env.store.Update("qm-demo", func(m *state.Manifest) {
		m.Cwd = repoRoot
		m.Agents = []state.AgentManifest{{Name: "claude", Role: "agent", CLI: "claude"}}
	}); err != nil {
		t.Fatalf("adopt manifest: %v", err)
	}

	change := (&FileChangeSource{stateRoot: env.store.Root()}).sessionManifestChange("qm-demo")
	if !change.BroadTracker {
		t.Fatalf("manifest change = %#v, want broad tracker refresh", change)
	}
	snap.Invalidate(change)
	got, err := snap.TrackerForChange(change)
	if err != nil {
		t.Fatalf("manifest-change Tracker: %v", err)
	}
	row := got.Sessions[0]
	if row.Agent != "claude" {
		t.Fatalf("agent = %q, want claude", row.Agent)
	}
	if row.WorktreePath != repoRoot || row.Repo.Name != "adopted" || row.Repo.Identity == "" {
		t.Fatalf("row repo/worktree = %#v, want adopted repo at %s", row, repoRoot)
	}
}

func TestSnapshotterTrackerSessionChangeKeepsCachedObservedAtUntilRowChanges(t *testing.T) {
	env := seedServeFixture(t)
	now := env.now
	snap := NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return now })

	cached, err := snap.TrackerForChange(Change{})
	if err != nil {
		t.Fatalf("initial Tracker: %v", err)
	}
	now = env.now.Add(time.Second)
	got, err := snap.TrackerForChange(Change{Topics: []string{topicTracker}, SessionIDs: []string{"qm-demo"}})
	if err != nil {
		t.Fatalf("no-op session Tracker: %v", err)
	}
	if !reflect.DeepEqual(got, cached) {
		t.Fatalf("no-op session tracker = %#v, want cached %#v", got, cached)
	}

	updateSessionActivity(t, now)
	now = env.now.Add(2 * time.Second)
	got, err = snap.TrackerForChange(Change{Topics: []string{topicTracker}, SessionIDs: []string{"qm-demo"}})
	if err != nil {
		t.Fatalf("changed session Tracker: %v", err)
	}
	if !got.ObservedAt.Equal(now) {
		t.Fatalf("changed ObservedAt = %v, want %v", got.ObservedAt, now)
	}
	if got.Sessions[0].State != "blocked" || got.Sessions[0].LatestActivity != "Question: approve?" {
		t.Fatalf("changed tracker row = %#v, want blocked Question activity", got.Sessions)
	}
}

func TestSnapshotterTrackerBroadRepoColorChangeCoalescedWithSessionRefreshes(t *testing.T) {
	env := seedServeFixture(t)
	snap := NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return env.now })
	color := "#111111"
	fetches := 0
	snap.fetcher = func(tracker.SessionInfo) (tracker.TrackerSnapshot, error) {
		fetches++
		return tracker.TrackerSnapshot{
			ObservedAt: env.now,
			Sessions: []tracker.SessionRow{{
				ID:           "qm-demo",
				Title:        "Serve runtime JSON",
				Status:       "active",
				State:        "working",
				SessionType:  "master",
				Agent:        "codex",
				RepoColor:    color,
				DisplayColor: color,
			}},
		}, nil
	}

	if _, err := snap.TrackerForChange(Change{}); err != nil {
		t.Fatalf("initial Tracker: %v", err)
	}
	color = "#222222"
	broad := topicChange(topicTracker)
	broad.BroadTracker = true
	merged := mergeChanges(broad, Change{Topics: []string{topicTracker}, SessionIDs: []string{"qm-demo"}})
	if !merged.BroadTracker || len(merged.SessionIDs) != 1 {
		t.Fatalf("merged change lost its shape: %#v", merged)
	}
	snap.Invalidate(merged)
	got, err := snap.TrackerForChange(merged)
	if err != nil {
		t.Fatalf("merged Tracker: %v", err)
	}
	if fetches != 2 {
		t.Fatalf("full tracker fetches = %d, want a rebuild after repo color change", fetches)
	}
	if got.Sessions[0].DisplayColor != "#222222" || got.Sessions[0].Repo.Color != "#222222" {
		t.Fatalf("merged tracker row = %#v, want refreshed #222222 color", got.Sessions)
	}
}

func TestSnapshotterClockReconcilesDoneToIdle(t *testing.T) {
	env := seedServeFixture(t)
	now := env.now
	snap := NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return now })

	if err := state.UpdateSessionState("qm-demo", func(ss *state.SessionState) bool {
		pane := ss.Panes["agent"]
		pane.State = "done"
		pane.Activity = "Finished"
		pane.LastKind = "Stop"
		pane.LastEvent = now.Add(-state.DoneToIdleGrace + time.Second)
		pane.WorkingSince = time.Time{}
		ss.Panes["agent"] = pane
		return true
	}); err != nil {
		t.Fatalf("write done state: %v", err)
	}
	if _, err := snap.TrackerForChange(Change{}); err != nil {
		t.Fatalf("initial Tracker: %v", err)
	}

	now = env.now.Add(state.DoneToIdleGrace)
	got, err := snap.TrackerForChange(clockChange())
	if err != nil {
		t.Fatalf("clock Tracker: %v", err)
	}
	if got.Sessions[0].State != "idle" || got.Sessions[0].LatestActivity != "Finished" {
		t.Fatalf("clock tracker row = %#v, want reconciled idle state", got.Sessions)
	}
}

func TestSnapshotterClockLoadsTypicalWhenDoneRowFindsRunningTool(t *testing.T) {
	env := seedServeFixture(t)
	now := env.now
	if err := state.UpdateSessionState("qm-demo", func(ss *state.SessionState) bool {
		pane := ss.Panes["agent"]
		pane.State = "done"
		pane.Activity = "Finished"
		pane.LastKind = "Stop"
		pane.LastEvent = now.Add(-time.Second)
		ss.Panes["agent"] = pane
		return true
	}); err != nil {
		t.Fatalf("seed done state: %v", err)
	}
	for _, sample := range []time.Duration{4, 6, 8} {
		if err := state.RecordToolDurationAt(env.store.Root(), "codex", "Bash", "go test", sample*time.Second); err != nil {
			t.Fatalf("record duration: %v", err)
		}
	}
	snap := NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return now })
	snap.fetcher = func(tracker.SessionInfo) (tracker.TrackerSnapshot, error) {
		return tracker.TrackerSnapshot{ObservedAt: env.now, Sessions: []tracker.SessionRow{{
			ID: "qm-demo", Status: "active", State: "done", Agent: "codex",
		}}}, nil
	}
	if _, err := snap.TrackerForChange(Change{}); err != nil {
		t.Fatalf("initial Tracker: %v", err)
	}
	startedAt := now
	if err := state.UpdateSessionState("qm-demo", func(ss *state.SessionState) bool {
		pane := ss.Panes["agent"]
		pane.State = "working"
		pane.LastEvent = startedAt
		pane.RunningTools = []state.RunningTool{{CallID: "call-1", Tool: "Bash", Command: "go test", StartedAt: startedAt}}
		pane.Tool = "Bash"
		ss.Panes["agent"] = pane
		return true
	}); err != nil {
		t.Fatalf("seed running tool: %v", err)
	}
	stored, err := state.LoadSessionStateAt(env.store.Root(), "qm-demo")
	if err != nil || stored.Panes["agent"].State != "working" {
		t.Fatalf("stored running state = %+v, err %v", stored, err)
	}
	now = now.Add(time.Second)
	got, err := snap.TrackerForChange(clockChange())
	if err != nil {
		t.Fatalf("clock Tracker: %v", err)
	}
	if cast := got.Sessions[0].Cast; cast == nil || cast.TypicalMS != 6000 {
		t.Fatalf("clock row = %+v, want cast typical_ms 6000", got.Sessions[0])
	}
}

func TestServerClockChangeWithoutStateTransitionProducesNoWirePush(t *testing.T) {
	env := seedServeFixture(t)
	socketPath := tempSocketPath(t)
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()

	changes := newManualChangeSource()
	srv := &Server{
		SocketPath:    socketPath,
		Snapshotter:   NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return env.now }),
		ClockInterval: time.Hour,
		ChangeSource:  changes,
	}
	errc := serveInBackground(t, ctx, srv, socketPath)

	conn, enc, dec := dialServe(t, socketPath)
	defer conn.Close() //nolint:errcheck
	writeRequest(t, enc, map[string]any{
		"id":     "sub",
		"method": "subscribe",
		"topics": []string{"tracker"},
	})
	assertResponseTopic(t, dec, "subscribe")
	assertEventTopic(t, dec, "tracker")

	changes.Publish(clockChange())
	assertNoEvent(t, conn, dec, 250*time.Millisecond)

	cancel()
	if err := <-errc; err != nil {
		t.Fatalf("server returned error: %v", err)
	}
}

func TestFileChangeSourceClassifiesArtifactsJSONAsSessionChange(t *testing.T) {
	env := seedServeFixture(t)
	watcher, err := fsnotify.NewWatcher()
	if err != nil {
		t.Fatalf("create watcher: %v", err)
	}
	t.Cleanup(func() { _ = watcher.Close() })
	source := &FileChangeSource{
		snapshotter: NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return env.now }),
		watcher:     watcher,
		stateRoot:   env.store.Root(),
		watched:     map[string]struct{}{},
	}

	change := source.classify(filepath.Join(env.store.Root(), "qm-demo", "artifacts.json"))

	if !reflect.DeepEqual(change.Topics, []string{topicTracker}) {
		t.Fatalf("topics = %v, want tracker", change.Topics)
	}
	if !reflect.DeepEqual(change.SessionIDs, []string{"qm-demo"}) {
		t.Fatalf("session ids = %v, want qm-demo", change.SessionIDs)
	}

	change = source.classify(filepath.Join(env.store.Root(), "qm-demo.json"))
	if !reflect.DeepEqual(change.Topics, []string{topicTracker}) || !reflect.DeepEqual(change.SessionIDs, []string{"qm-demo"}) ||
		!change.BroadTracker || !change.Lifecycle {
		t.Fatalf("manifest change = %#v, want broad lifecycle tracker change for qm-demo", change)
	}

	change = source.classify(state.ArtifactsRegistryPath(env.store.Root()))
	if !reflect.DeepEqual(change.Topics, []string{topicTracker}) || !change.BroadTracker || len(change.SessionIDs) != 0 {
		t.Fatalf("root artifacts change = %#v, want broad tracker change", change)
	}

	change = source.classify(state.QuestsRegistryPath(env.store.Root()))
	if !reflect.DeepEqual(change.Topics, []string{topicTracker}) || !change.BroadTracker || len(change.SessionIDs) != 0 {
		t.Fatalf("root quests change = %#v, want broad tracker change", change)
	}
}

func TestFileChangeSourceWatchesOnlyManifestDirectories(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	for _, id := range []string{"qm-manifest", "qm-orphan"} {
		if err := os.Mkdir(filepath.Join(root, id), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	manifest := filepath.Join(root, "qm-manifest.json")
	if err := os.WriteFile(manifest, []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	source, err := NewFileChangeSource(t.Context(), NewSnapshotter(state.OpenStore(root), tmux.NewClient(fakeTmuxRunner{}), nil), time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	defer source.Close()
	assertWatches := func(want ...string) {
		t.Helper()
		source.mu.Lock()
		defer source.mu.Unlock()
		if len(source.watched) != len(want) {
			t.Fatalf("watched=%v, want %v", source.watched, want)
		}
		for _, path := range want {
			if _, ok := source.watched[path]; !ok {
				t.Fatalf("%s not watched: %v", path, source.watched)
			}
		}
	}
	assertWatches(root, filepath.Join(root, "qm-manifest"))
	if err := os.Remove(manifest); err != nil {
		t.Fatal(err)
	}
	if err := source.watchSessionDir("qm-manifest"); err != nil {
		t.Fatal(err)
	}
	assertWatches(root)
	if err := os.WriteFile(filepath.Join(root, "qm-orphan.json"), []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := source.watchSessionDir("qm-orphan"); err != nil {
		t.Fatal(err)
	}
	assertWatches(root, filepath.Join(root, "qm-orphan"))
}

func TestFileChangeSourceSlowSubscriberCoalescesWithoutBlockingOthers(t *testing.T) {
	t.Parallel()
	slow := make(chan Change, 1)
	fast := make(chan Change, 2)
	source := &FileChangeSource{subscribers: map[chan Change]struct{}{slow: {}, fast: {}}}
	source.publish(topicChange(topicModels))
	done := make(chan struct{})
	go func() {
		source.publish(topicChange(topicDirSuggest))
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("stalled subscriber blocked watcher publication")
	}
	if got := <-slow; !reflect.DeepEqual(got.Topics, []string{topicTracker}) {
		t.Fatalf("slow subscriber did not coalesce to all topics: %+v", got)
	}
	if first, second := <-fast, <-fast; !reflect.DeepEqual(first.Topics, []string{topicModels}) || !reflect.DeepEqual(second.Topics, []string{topicDirSuggest}) {
		t.Fatalf("fast subscriber missed changes: first=%+v second=%+v", first, second)
	}
}

func TestFileChangeSourceClassifiesStateJSONLAsSessionChange(t *testing.T) {
	env := seedServeFixture(t)
	source := &FileChangeSource{
		snapshotter: NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return env.now }),
		stateRoot:   env.store.Root(),
	}

	for _, name := range []string{"state.jsonl", "state.jsonl.1"} {
		change := source.classify(filepath.Join(env.store.Root(), "qm-demo", name))
		if !reflect.DeepEqual(change.Topics, []string{topicTracker}) {
			t.Fatalf("%s topics = %v, want tracker", name, change.Topics)
		}
		if !reflect.DeepEqual(change.SessionIDs, []string{"qm-demo"}) {
			t.Fatalf("%s session ids = %v, want qm-demo", name, change.SessionIDs)
		}
		if change.BroadTracker || change.Lifecycle {
			t.Fatalf("%s change = %#v, want narrow session tracker change", name, change)
		}
	}
}

func TestFileChangeSourceBurstFlushesAtMaxWait(t *testing.T) {
	const sessionID = "qm-burst"
	root := filepath.Join(t.TempDir(), "state")
	t.Setenv(state.StateRootEnv, root)
	store, err := state.NewStore(root)
	if err != nil {
		t.Fatalf("state store: %v", err)
	}
	if err := store.Create(state.Manifest{
		SessionID:   sessionID,
		Title:       "Burst debounce",
		SessionType: "master",
		Agents:      []state.AgentManifest{{Name: "codex", Role: "agent"}},
	}); err != nil {
		t.Fatalf("create manifest: %v", err)
	}
	if err := writeWatchTestSessionState(root, sessionID, "initial"); err != nil {
		t.Fatalf("write initial state: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	source, err := NewFileChangeSource(
		ctx,
		NewSnapshotter(store, tmux.NewClient(fakeTmuxRunner{sessions: sessionID}), time.Now),
		time.Hour,
	)
	if err != nil {
		t.Fatalf("new file change source: %v", err)
	}
	t.Cleanup(func() {
		if err := source.Close(); err != nil {
			t.Fatalf("close source: %v", err)
		}
	})
	changes, unsubscribe := source.Subscribe(ctx)
	t.Cleanup(unsubscribe)

	const writeCount = 20
	writeInterval := 50 * time.Millisecond
	burstDuration := time.Duration(writeCount-1) * writeInterval
	writerDone := make(chan error, 1)
	started := time.Now()
	go func() {
		for i := 0; i < writeCount; i++ {
			if err := writeWatchTestSessionState(root, sessionID, fmt.Sprintf("burst %02d", i)); err != nil {
				writerDone <- err
				return
			}
			if i < writeCount-1 {
				time.Sleep(writeInterval)
			}
		}
		writerDone <- nil
	}()

	var elapsed time.Duration
	deadline := time.After(2 * time.Second)
	for {
		select {
		case err := <-writerDone:
			if err != nil {
				t.Fatalf("write burst: %v", err)
			}
			t.Fatal("burst finished before the first publish; want max-wait flush during sustained writes")
		case change := <-changes:
			if contains(change.Topics, topicTracker) {
				elapsed = time.Since(started)
				goto gotChange
			}
		case <-deadline:
			t.Fatal("timed out waiting for burst publish")
		}
	}

gotChange:
	if elapsed >= burstDuration {
		t.Fatalf("first publish after %s, want before burst ends at %s", elapsed, burstDuration)
	}
	if elapsed > watchDebounceMaxWait+400*time.Millisecond {
		t.Fatalf("first publish after %s, want near max wait %s", elapsed, watchDebounceMaxWait)
	}
	if err := <-writerDone; err != nil {
		t.Fatalf("write burst: %v", err)
	}
}

func TestServerSessionMutationEndpointsReexecQM(t *testing.T) {
	env := seedServeFixture(t)
	socketPath := tempSocketPath(t)
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()

	runner := &recordingMutationRunner{}
	srv := &Server{
		SocketPath:     socketPath,
		Snapshotter:    NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return env.now }),
		ClockInterval:  time.Hour,
		MutationRunner: runner,
	}
	errc := serveInBackground(t, ctx, srv, socketPath)

	tests := []struct {
		name      string
		request   map[string]any
		wantArgs  []string
		wantStdin string
	}{
		{
			name: "delete",
			request: map[string]any{
				"id":     "delete",
				"method": "delete",
				"data":   map[string]any{"session_id": "qm-old"},
			},
			wantArgs: []string{"delete", "qm-old"},
		},
		{
			name: "continue",
			request: map[string]any{
				"id":     "continue",
				"method": "continue",
				"data":   map[string]any{"session_id": "qm-stopped"},
			},
			wantArgs: []string{"continue", "qm-stopped"},
		},
		{
			name: "spawn",
			request: map[string]any{
				"id":     "spawn",
				"method": "spawn",
				"data": map[string]any{
					"master_id": "qm-master",
					"title":     "worker title",
					"cwd":       "/tmp/worker",
					"agent":     "codex",
					"prompt":    "work this",
				},
			},
			wantArgs:  []string{"spawn", "--from-app", "--cwd", "/tmp/worker", "--agent", "codex", "--prompt-file", "-", "--", "qm-master", "worker title"},
			wantStdin: "work this",
		},
		{
			name: "start",
			request: map[string]any{
				"id":     "start",
				"method": "start",
				"data": map[string]any{
					"title":  "session title",
					"cwd":    "/tmp/project",
					"agent":  "codex",
					"color":  "violet",
					"class":  "wizard",
					"prompt": "start this",
				},
			},
			wantArgs:  []string{"start", "--from-app", "--cwd", "/tmp/project", "--agent", "codex", "--color", "violet", "--class", "wizard", "--prompt-file", "-", "--", "session title"},
			wantStdin: "start this",
		},
		{
			name: "start shell",
			request: map[string]any{
				"id":     "start-shell",
				"method": "start",
				"data": map[string]any{
					"title": "plain terminal",
					"cwd":   "/tmp/project",
					"shell": "true",
				},
			},
			wantArgs: []string{"start", "--from-app", "--cwd", "/tmp/project", "--shell", "--", "plain terminal"},
		},
		{
			// An unrecognized model is forwarded verbatim: the harness, not
			// questmaster, decides whether a model exists.
			name: "start with model override",
			request: map[string]any{
				"id":     "start-model",
				"method": "start",
				"data": map[string]any{
					"cwd":   "/tmp/project",
					"agent": "claude",
					"model": "claude-opus-9-unreleased",
				},
			},
			wantArgs: []string{"start", "--from-app", "--cwd", "/tmp/project", "--agent", "claude", "--model", "claude-opus-9-unreleased"},
		},
		{
			name: "start shell ignores a model",
			request: map[string]any{
				"id":     "start-shell-model",
				"method": "start",
				"data": map[string]any{
					"cwd":   "/tmp/project",
					"shell": "true",
					"model": "claude-opus-5",
				},
			},
			wantArgs: []string{"start", "--from-app", "--cwd", "/tmp/project", "--shell"},
		},
		{
			name: "spawn with model override",
			request: map[string]any{
				"id":     "spawn-model",
				"method": "spawn",
				"data": map[string]any{
					"master_id": "qm-master",
					"cwd":       "/tmp/worker",
					"agent":     "codex",
					"model":     "gpt-5.6-sol",
				},
			},
			wantArgs: []string{"spawn", "--from-app", "--cwd", "/tmp/worker", "--agent", "codex", "--model", "gpt-5.6-sol", "--", "qm-master"},
		},
		{
			name: "start with reasoning effort override",
			request: map[string]any{
				"id":     "start-effort",
				"method": "start",
				"data": map[string]any{
					"cwd":              "/tmp/project",
					"agent":            "claude",
					"reasoning_effort": "max",
				},
			},
			wantArgs: []string{"start", "--from-app", "--cwd", "/tmp/project", "--agent", "claude", "--reasoning-effort", "max"},
		},
		{
			name: "start shell ignores a reasoning effort",
			request: map[string]any{
				"id":     "start-shell-effort",
				"method": "start",
				"data": map[string]any{
					"cwd":              "/tmp/project",
					"shell":            "true",
					"reasoning_effort": "max",
				},
			},
			wantArgs: []string{"start", "--from-app", "--cwd", "/tmp/project", "--shell"},
		},
		{
			name: "spawn with reasoning effort override",
			request: map[string]any{
				"id":     "spawn-effort",
				"method": "spawn",
				"data": map[string]any{
					"master_id":        "qm-master",
					"cwd":              "/tmp/worker",
					"agent":            "codex",
					"reasoning_effort": "high",
				},
			},
			wantArgs: []string{"spawn", "--from-app", "--cwd", "/tmp/worker", "--agent", "codex", "--reasoning-effort", "high", "--", "qm-master"},
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			runner.Reset()
			env := sendMutation(t, socketPath, tc.request)
			if env.Type != "response" || env.OK == nil || !*env.OK {
				t.Fatalf("mutation response = %#v, want ok", env)
			}
			got := runner.Commands()
			if len(got) != 1 {
				t.Fatalf("commands = %#v, want one", got)
			}
			if !reflect.DeepEqual(got[0].Args, tc.wantArgs) || got[0].Stdin != tc.wantStdin {
				t.Fatalf("command = %#v, want args %#v stdin %q", got[0], tc.wantArgs, tc.wantStdin)
			}
		})
	}

	cancel()
	if err := <-errc; err != nil {
		t.Fatalf("server returned error: %v", err)
	}
}

func TestSessionMutationsRejectLegacyAgentField(t *testing.T) {
	for _, method := range []string{"start", "spawn"} {
		t.Run(method, func(t *testing.T) {
			runner := &recordingMutationRunner{}
			srv := &Server{MutationRunner: runner}
			_, err := srv.mutate(context.Background(), Request{
				Method: method,
				Data:   json.RawMessage(`{"primary":"codex"}`),
			})
			if err == nil || !strings.Contains(err.Error(), `unsupported field "primary"`) {
				t.Fatalf("mutate error = %v, want unsupported field error", err)
			}
			if commands := runner.Commands(); len(commands) != 0 {
				t.Fatalf("commands = %#v, want none", commands)
			}
		})
	}
}

func TestMutationMethodRegistryDrivesRouting(t *testing.T) {
	methods := mutationMethodNames()
	if len(methods) == 0 {
		t.Fatal("mutation registry is empty")
	}
	for _, method := range methods {
		if !isMutationMethod(method) {
			t.Fatalf("registered mutation method %q is not routed as a mutation", method)
		}
		if !isMutationMethod("mutation." + method) {
			t.Fatalf("registered mutation method %q is not routed through mutation. prefix", method)
		}
	}
	for _, method := range []string{"mutate", "unknown", "mutation.unknown", "tracker", "relay", "broadcast", "mutation.relay", "mutation.broadcast"} {
		if isMutationMethod(method) {
			t.Fatalf("unregistered method %q routed as mutation", method)
		}
	}
}

func TestQuestEditMutationUpdatesAndClearsProject(t *testing.T) {
	store, err := state.NewStore(t.TempDir())
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	if _, err := state.UpsertQuestAt(store.Root(), state.Quest{
		ID:          "qst-edit",
		Content:     "Original",
		ProjectID:   "repo-a",
		ProjectPath: "/tmp/repo-a",
		ProjectName: "Repo A",
	}); err != nil {
		t.Fatalf("seed quest: %v", err)
	}
	server := &Server{Snapshotter: &Snapshotter{store: store}}

	editData, _ := json.Marshal(map[string]string{
		"quest_id":        "qst-edit",
		"content":         "Updated",
		"project_changed": "true",
		"project_id":      "repo-b",
		"project_path":    "/tmp/repo-b",
		"project_name":    "Repo B",
	})
	if _, err := server.mutate(t.Context(), Request{Method: "quest.edit", Data: editData}); err != nil {
		t.Fatalf("edit quest project: %v", err)
	}
	quests, err := state.LoadQuestsAt(store.Root())
	if err != nil {
		t.Fatalf("load edited quest: %v", err)
	}
	if len(quests) != 1 || quests[0].ProjectID != "repo-b" || quests[0].ProjectPath != "/tmp/repo-b" || quests[0].ProjectName != "Repo B" {
		t.Fatalf("edited quest = %#v, want repo-b metadata", quests)
	}

	clearData, _ := json.Marshal(map[string]string{
		"quest_id":        "qst-edit",
		"content":         "Updated",
		"project_changed": "true",
	})
	if _, err := server.mutate(t.Context(), Request{Method: "quest.edit", Data: clearData}); err != nil {
		t.Fatalf("clear quest project: %v", err)
	}
	quests, err = state.LoadQuestsAt(store.Root())
	if err != nil {
		t.Fatalf("load cleared quest: %v", err)
	}
	if len(quests) != 1 || quests[0].ProjectID != "" || quests[0].ProjectPath != "" || quests[0].ProjectName != "" {
		t.Fatalf("cleared quest = %#v, want no project metadata", quests)
	}
}

func TestQuestMutationsResolveAProjectSentAsAPathOnly(t *testing.T) {
	t.Parallel()
	store, err := state.NewStore(t.TempDir())
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	root := filepath.Join(t.TempDir(), "realm")
	sub := filepath.Join(root, "app")
	if err := os.MkdirAll(filepath.Join(root, ".git"), 0o755); err != nil {
		t.Fatalf("git dir: %v", err)
	}
	if err := os.MkdirAll(sub, 0o755); err != nil {
		t.Fatalf("sub dir: %v", err)
	}
	wantID, wantPath, wantName, err := state.ResolveQuestProject(sub, true)
	if err != nil || wantID == "" || wantName != "realm" || wantPath != sub {
		t.Fatalf("resolve %s = %q %q %q, %v", sub, wantID, wantPath, wantName, err)
	}
	server := &Server{Snapshotter: &Snapshotter{store: store}}

	addData, _ := json.Marshal(map[string]string{"content": "Typed path", "project_path": sub})
	if _, err := server.mutate(t.Context(), Request{Method: "quest.add", Data: addData}); err != nil {
		t.Fatalf("add quest: %v", err)
	}
	quests, err := state.LoadQuestsAt(store.Root())
	if err != nil {
		t.Fatalf("load quests: %v", err)
	}
	if len(quests) != 1 || quests[0].ProjectID != wantID || quests[0].ProjectPath != wantPath || quests[0].ProjectName != wantName {
		t.Fatalf("added quest = %#v, want the CLI's project %q %q %q", quests, wantID, wantPath, wantName)
	}

	other := filepath.Join(t.TempDir(), "other")
	if err := os.MkdirAll(filepath.Join(other, ".git"), 0o755); err != nil {
		t.Fatalf("other git dir: %v", err)
	}
	editData, _ := json.Marshal(map[string]string{"quest_id": quests[0].ID, "content": "Typed path", "project_changed": "true", "project_path": other})
	if _, err := server.mutate(t.Context(), Request{Method: "quest.edit", Data: editData}); err != nil {
		t.Fatalf("edit quest: %v", err)
	}
	quests, err = state.LoadQuestsAt(store.Root())
	if err != nil {
		t.Fatalf("load edited quests: %v", err)
	}
	if len(quests) != 1 || quests[0].ProjectName != "other" || quests[0].ProjectPath != other || quests[0].ProjectID == wantID {
		t.Fatalf("edited quest = %#v, want the other repo", quests)
	}

	rejected := map[string]struct {
		path string
		want string
	}{
		"outside a repo":          {path: t.TempDir(), want: "not in a git repo"},
		"missing dir in a repo":   {path: filepath.Join(root, "missing"), want: "not a directory"},
		"file in a repo":          {path: writeQuestTestFile(t, root), want: "not a directory"},
		"relative to serve's cwd": {path: "realm/app", want: "must be absolute"},
		"another user's home":     {path: "~nobody/realm", want: "must be absolute"},
	}
	for name, tc := range rejected {
		data, _ := json.Marshal(map[string]string{"content": "Nowhere", "project_path": tc.path})
		if _, err := server.mutate(t.Context(), Request{Method: "quest.add", Data: data}); err == nil || !strings.Contains(err.Error(), tc.want) {
			t.Fatalf("%s: add %q: err = %v, want %q", name, tc.path, err, tc.want)
		}
	}
}

func writeQuestTestFile(t *testing.T, dir string) string {
	t.Helper()
	path := filepath.Join(dir, "notes.txt")
	if err := os.WriteFile(path, []byte("x"), 0o644); err != nil {
		t.Fatalf("write file: %v", err)
	}
	return path
}

func TestExpandHomeExpandsOnlyTheUsersHome(t *testing.T) {
	t.Parallel()
	home, err := os.UserHomeDir()
	if err != nil {
		t.Skipf("no home: %v", err)
	}
	cases := map[string]string{
		"~":          home,
		"~/Code/x":   filepath.Join(home, "Code/x"),
		"~nobody/x":  "~nobody/x",
		"/abs/~/x":   "/abs/~/x",
		"relative/x": "relative/x",
	}
	for in, want := range cases {
		if got := state.ExpandHome(in); got != want {
			t.Fatalf("ExpandHome(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestArtifactDeleteMutationRemovesSessionAndGlobalArtifacts(t *testing.T) {
	store, err := state.NewStore(t.TempDir())
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	server := &Server{Snapshotter: &Snapshotter{store: store}}
	tests := []struct {
		name     string
		mutation map[string]string
		seed     func() error
		wantPath string
	}{
		{
			name:     "session artifact",
			mutation: map[string]string{"path": "/tmp/session-report.html", "session_id": "qm-demo"},
			seed: func() error {
				return state.UpsertArtifactAt(store.Root(), "qm-demo", state.Artifact{Path: "/tmp/session-report.html"})
			},
			wantPath: "/tmp/session-report.html",
		},
		{
			name:     "global artifact",
			mutation: map[string]string{"path": "/tmp/global-report.html"},
			seed: func() error {
				return state.UpsertArtifactGlobal(store.Root(), state.Artifact{Path: "/tmp/global-report.html"})
			},
			wantPath: "/tmp/global-report.html",
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if err := tc.seed(); err != nil {
				t.Fatalf("seed artifact: %v", err)
			}
			data, err := json.Marshal(tc.mutation)
			if err != nil {
				t.Fatalf("encode mutation: %v", err)
			}
			if _, err := server.mutate(t.Context(), Request{Method: "artifact.delete", Data: data}); err != nil {
				t.Fatalf("delete artifact: %v", err)
			}
			artifacts, err := state.LoadArtifactsGlobal(store.Root())
			if err != nil {
				t.Fatalf("load artifacts: %v", err)
			}
			if anyArtifactHasPath(artifacts, tc.wantPath) {
				t.Fatalf("artifacts = %#v, want %q removed", artifacts, tc.wantPath)
			}
		})
	}
}

func anyArtifactHasPath(artifacts []state.Artifact, path string) bool {
	for _, artifact := range artifacts {
		if artifact.Path == path {
			return true
		}
	}
	return false
}

func TestServerDirSuggestReturnsPickerSuggestionsAndRecents(t *testing.T) {
	env := seedServeFixture(t)
	socketPath := tempSocketPath(t)
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()

	var gotQuery string
	srv := &Server{
		SocketPath:    socketPath,
		Snapshotter:   NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return env.now }),
		ClockInterval: time.Hour,
		DirQuerier: func(query string) ([]string, error) {
			gotQuery = query
			return []string{"/tmp/not-a-match", "/tmp/project-app", "/tmp/project-log"}, nil
		},
	}
	errc := serveInBackground(t, ctx, srv, socketPath)

	conn, enc, dec := dialServe(t, socketPath)
	defer conn.Close() //nolint:errcheck
	writeRequest(t, enc, map[string]any{
		"id":     "dir",
		"method": "dir_suggest",
		"data":   map[string]any{"query": "project"},
	})
	envResp := assertResponseTopic(t, dec, "dir_suggest")
	if gotQuery != "project" {
		t.Fatalf("dir query = %q, want project", gotQuery)
	}
	data, ok := envResp.Data.(map[string]any)
	if !ok {
		t.Fatalf("dir_suggest data = %#v, want object", envResp.Data)
	}
	suggestions := stringList(data["suggestions"])
	if !reflect.DeepEqual(suggestions, []string{"/tmp/project-app", "/tmp/project-log"}) {
		t.Fatalf("suggestions = %v, want ranked project matches", suggestions)
	}
	recents := stringList(data["recents"])
	if !stringListContains(recents, env.worktree) {
		t.Fatalf("recents = %v, want %s", recents, env.worktree)
	}

	cancel()
	if err := <-errc; err != nil {
		t.Fatalf("server returned error: %v", err)
	}
}

func TestServerModelsTopicServesSuggestionsForOneAgent(t *testing.T) {
	env := seedServeFixture(t)
	// Never reach the network from a test: with fetching off and no cache,
	// suggestions rely only on recents and the persisted role default —
	// there is no hardcoded per-harness floor anymore.
	t.Setenv(modelsuggest.CatalogURLEnv, "off")
	if err := env.store.Create(state.Manifest{
		SessionID: "qm-recent-claude",
		Cwd:       t.TempDir(),
		Agents:    []state.AgentManifest{{Name: "claude", Role: "agent", Model: "claude-opus-9-unreleased"}},
	}); err != nil {
		t.Fatalf("seed recent model: %v", err)
	}
	if err := state.NewRoleDefaultsStore(env.store.Root()).Set("claude", "master", state.RoleDefault{Model: "opus"}); err != nil {
		t.Fatalf("seed role default: %v", err)
	}
	socketPath := tempSocketPath(t)
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()

	srv := &Server{
		SocketPath:    socketPath,
		Snapshotter:   NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return env.now }),
		ClockInterval: time.Hour,
	}
	errc := serveInBackground(t, ctx, srv, socketPath)

	conn, enc, dec := dialServe(t, socketPath)
	defer conn.Close() //nolint:errcheck

	writeRequest(t, enc, map[string]any{
		"id":     "models",
		"method": "models",
		"data":   map[string]any{"agent": "claude", "role": "master"},
	})
	envResp := assertResponseTopic(t, dec, "models")
	data, ok := envResp.Data.(map[string]any)
	if !ok {
		t.Fatalf("models data = %#v, want object", envResp.Data)
	}
	if data["agent"] != "claude" || data["role"] != "master" {
		t.Fatalf("models data = %#v, want claude/master", data)
	}
	if data["default"] != "opus" {
		t.Fatalf("models default = %#v, want the persisted role default opus", data["default"])
	}
	models, ok := data["models"].([]any)
	if !ok || len(models) != 2 {
		t.Fatalf("models = %#v, want the recent model plus the backfilled persisted default", data["models"])
	}

	// limit caps the ranked, dynamic part of the list, but the persisted
	// default always survives past it (it's backfilled after truncation) —
	// so limit=1 here still yields 2: the one ranked entry plus the default.
	writeRequest(t, enc, map[string]any{
		"id":     "models-limit",
		"method": "models",
		"data":   map[string]any{"agent": "claude", "role": "master", "limit": 1},
	})
	limited := assertResponseTopic(t, dec, "models")
	limitedData, ok := limited.Data.(map[string]any)
	if !ok {
		t.Fatalf("models limit data = %#v, want object", limited.Data)
	}
	limitedModels, ok := limitedData["models"].([]any)
	if !ok || len(limitedModels) != 2 {
		t.Fatalf("models with limit=1 = %#v, want the one ranked entry plus the backfilled default", limitedData["models"])
	}

	// query filters the list: a substring that matches nothing must yield no
	// models, even the backfilled persisted default.
	writeRequest(t, enc, map[string]any{
		"id":     "models-query-match",
		"method": "models",
		"data":   map[string]any{"agent": "claude", "role": "master", "query": "unreleased"},
	})
	matched := assertResponseTopic(t, dec, "models")
	matchedData, ok := matched.Data.(map[string]any)
	if !ok {
		t.Fatalf("models query data = %#v, want object", matched.Data)
	}
	matchedModels, _ := matchedData["models"].([]any)
	if len(matchedModels) == 0 {
		t.Fatalf("models query=unreleased = %#v, want at least the recent model", matchedData["models"])
	}

	writeRequest(t, enc, map[string]any{
		"id":     "models-query-nomatch",
		"method": "models",
		"data":   map[string]any{"agent": "claude", "role": "master", "query": "zzz-does-not-match-anything"},
	})
	unmatched := assertResponseTopic(t, dec, "models")
	unmatchedData, ok := unmatched.Data.(map[string]any)
	if !ok {
		t.Fatalf("models query data = %#v, want object", unmatched.Data)
	}
	if unmatchedModels, _ := unmatchedData["models"].([]any); len(unmatchedModels) != 0 {
		t.Fatalf("models with a non-matching query = %#v, want none", unmatchedData["models"])
	}

	// refresh must decode without error (its cache-bypass effect is covered
	// at the modelsuggest package level).
	writeRequest(t, enc, map[string]any{
		"id":     "models-refresh",
		"method": "models",
		"data":   map[string]any{"agent": "claude", "role": "master", "refresh": true},
	})
	assertResponseTopic(t, dec, "models")

	// A request without an agent is a client error, not an empty list.
	writeRequest(t, enc, map[string]any{"id": "models-missing", "method": "models"})
	var errEnv Envelope
	if err := dec.Decode(&errEnv); err != nil {
		t.Fatalf("decode models error envelope: %v", err)
	}
	if errEnv.OK == nil || *errEnv.OK || errEnv.Error == "" {
		t.Fatalf("models without an agent = %#v, want an error envelope", errEnv)
	}

	cancel()
	if err := <-errc; err != nil {
		t.Fatalf("server returned error: %v", err)
	}
}

func TestServerReasoningEffortsTopicServesLevelsForOneAgentAndModel(t *testing.T) {
	env := seedServeFixture(t)
	socketPath := tempSocketPath(t)
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()

	srv := &Server{
		SocketPath:    socketPath,
		Snapshotter:   NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return env.now }),
		ClockInterval: time.Hour,
		ReasoningEfforts: func(_ context.Context, agentName, model string) []string {
			if agentName == "codex" && model == "gpt-6-luna" {
				return []string{"low", "medium", "high", "xhigh", "max"}
			}
			return nil
		},
	}
	errc := serveInBackground(t, ctx, srv, socketPath)

	conn, enc, dec := dialServe(t, socketPath)
	defer conn.Close() //nolint:errcheck

	if err := state.NewRoleDefaultsStore(env.store.Root()).Set("codex", "master", state.RoleDefault{ReasoningEffort: "xhigh"}); err != nil {
		t.Fatalf("seed role default: %v", err)
	}

	writeRequest(t, enc, map[string]any{
		"id":     "reasoning-efforts",
		"method": "reasoning_efforts",
		"data":   map[string]any{"agent": "codex", "role": "master", "model": "gpt-6-luna"},
	})
	envResp := assertResponseTopic(t, dec, "reasoning_efforts")
	data, ok := envResp.Data.(map[string]any)
	if !ok {
		t.Fatalf("reasoning_efforts data = %#v, want object", envResp.Data)
	}
	if data["agent"] != "codex" || data["role"] != "master" {
		t.Fatalf("reasoning_efforts data = %#v, want codex/master", data)
	}
	if data["default"] != "xhigh" {
		t.Fatalf("reasoning_efforts default = %#v, want the persisted role default xhigh", data["default"])
	}
	efforts := stringList(data["efforts"])
	if !reflect.DeepEqual(efforts, []string{"low", "medium", "high", "xhigh", "max"}) {
		t.Fatalf("reasoning_efforts efforts = %v, want the reported gpt-6-luna levels", efforts)
	}

	// An unrecognized OpenCode model has no reported levels and no forced
	// default either.
	writeRequest(t, enc, map[string]any{
		"id":     "reasoning-efforts-opencode-unknown",
		"method": "reasoning_efforts",
		"data":   map[string]any{"agent": "opencode", "role": "worker", "model": "ollama/local-llm-9"},
	})
	unknownResp := assertResponseTopic(t, dec, "reasoning_efforts")
	unknownData, ok := unknownResp.Data.(map[string]any)
	if !ok {
		t.Fatalf("reasoning_efforts data = %#v, want object", unknownResp.Data)
	}
	if unknownData["default"] != "" {
		t.Fatalf("reasoning_efforts default = %#v, want no configured default", unknownData["default"])
	}
	if len(stringList(unknownData["efforts"])) != 0 {
		t.Fatalf("reasoning_efforts efforts = %#v, want none for an unrecognized OpenCode provider", unknownData["efforts"])
	}

	// A request without an agent is a client error, not an empty list.
	writeRequest(t, enc, map[string]any{"id": "reasoning-efforts-missing", "method": "reasoning_efforts"})
	var errEnv Envelope
	if err := dec.Decode(&errEnv); err != nil {
		t.Fatalf("decode reasoning_efforts error envelope: %v", err)
	}
	if errEnv.OK == nil || *errEnv.OK || errEnv.Error == "" {
		t.Fatalf("reasoning_efforts without an agent = %#v, want an error envelope", errEnv)
	}

	cancel()
	if err := <-errc; err != nil {
		t.Fatalf("server returned error: %v", err)
	}
}

// TestServerReasoningEffortsTopicUsesPersistedModelWhenCallerModelIsEmpty
// guards the Settings sheet's first-open request: it fires a row's model and
// reasoning_efforts requests at the same time, so the very first
// reasoning_efforts call for a row goes out with an empty model (the model
// request hasn't resolved yet). If that empty model were read literally,
// model-specific levels would be missing from Efforts even though they are
// exactly the persisted override — reproducing a
// real incident where confirming Settings without touching that row silently
// cleared its already-configured reasoning effort.
func TestServerReasoningEffortsTopicUsesPersistedModelWhenCallerModelIsEmpty(t *testing.T) {
	env := seedServeFixture(t)
	if err := state.NewRoleDefaultsStore(env.store.Root()).Set("codex", "worker", state.RoleDefault{
		Model:           "gpt-5.6-luna",
		ReasoningEffort: "max",
	}); err != nil {
		t.Fatalf("seed role default: %v", err)
	}
	socketPath := tempSocketPath(t)
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()

	srv := &Server{
		SocketPath:    socketPath,
		Snapshotter:   NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return env.now }),
		ClockInterval: time.Hour,
		ReasoningEfforts: func(_ context.Context, agentName, model string) []string {
			if agentName == "codex" && model == "gpt-5.6-luna" {
				return []string{"low", "medium", "high", "xhigh", "max"}
			}
			return nil
		},
	}
	errc := serveInBackground(t, ctx, srv, socketPath)

	conn, enc, dec := dialServe(t, socketPath)
	defer conn.Close() //nolint:errcheck

	writeRequest(t, enc, map[string]any{
		"id":     "reasoning-efforts-empty-model",
		"method": "reasoning_efforts",
		"data":   map[string]any{"agent": "codex", "role": "worker", "model": ""},
	})
	resp := assertResponseTopic(t, dec, "reasoning_efforts")
	data, ok := resp.Data.(map[string]any)
	if !ok {
		t.Fatalf("reasoning_efforts data = %#v, want object", resp.Data)
	}
	if data["default"] != "max" {
		t.Fatalf("reasoning_efforts default = %#v, want max", data["default"])
	}
	efforts := stringList(data["efforts"])
	if !slices.Contains(efforts, "max") {
		t.Fatalf("reasoning_efforts efforts = %v, want the persisted override's model to shape the list (max present)", efforts)
	}

	cancel()
	if err := <-errc; err != nil {
		t.Fatalf("server returned error: %v", err)
	}
}

// TestServerModelsAndReasoningEffortsTopicsReflectPersistedRoleDefault guards
// the read side of Settings: once a default is persisted, the same topics the
// New Session sheet already polls must report it, without any wire-shape
// change.
func TestServerModelsAndReasoningEffortsTopicsReflectPersistedRoleDefault(t *testing.T) {
	env := seedServeFixture(t)
	t.Setenv(modelsuggest.CatalogURLEnv, "off")
	if err := state.NewRoleDefaultsStore(env.store.Root()).Set("claude", "worker", state.RoleDefault{
		Model:           "claude-opus-9-unreleased",
		ReasoningEffort: "low",
	}); err != nil {
		t.Fatalf("seed role default: %v", err)
	}
	socketPath := tempSocketPath(t)
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()

	srv := &Server{
		SocketPath:    socketPath,
		Snapshotter:   NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return env.now }),
		ClockInterval: time.Hour,
		ReasoningEfforts: func(_ context.Context, agentName, _ string) []string {
			if agentName == "claude" {
				return []string{"low", "medium", "high", "xhigh", "max"}
			}
			return nil
		},
	}
	errc := serveInBackground(t, ctx, srv, socketPath)

	conn, enc, dec := dialServe(t, socketPath)
	defer conn.Close() //nolint:errcheck

	writeRequest(t, enc, map[string]any{
		"id":     "models",
		"method": "models",
		"data":   map[string]any{"agent": "claude", "role": "worker"},
	})
	modelsResp := assertResponseTopic(t, dec, "models")
	modelsData, ok := modelsResp.Data.(map[string]any)
	if !ok || modelsData["default"] != "claude-opus-9-unreleased" {
		t.Fatalf("models default = %#v, want the persisted role default", modelsResp.Data)
	}

	writeRequest(t, enc, map[string]any{
		"id":     "reasoning-efforts",
		"method": "reasoning_efforts",
		"data":   map[string]any{"agent": "claude", "role": "worker"},
	})
	effortsResp := assertResponseTopic(t, dec, "reasoning_efforts")
	effortsData, ok := effortsResp.Data.(map[string]any)
	if !ok || effortsData["default"] != "low" {
		t.Fatalf("reasoning_efforts default = %#v, want the persisted role default", effortsResp.Data)
	}

	cancel()
	if err := <-errc; err != nil {
		t.Fatalf("server returned error: %v", err)
	}
}

func TestServerRecolorMutationMutatesStateAndPushesTracker(t *testing.T) {
	env := seedServeFixture(t)
	if err := os.MkdirAll(filepath.Join(env.worktree, ".git"), 0o755); err != nil {
		t.Fatalf("create fixture .git: %v", err)
	}
	repoIdentity, err := filepath.EvalSymlinks(filepath.Join(env.worktree, ".git"))
	if err != nil {
		t.Fatalf("resolve repo identity: %v", err)
	}
	socketPath := tempSocketPath(t)
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()

	runner := &recordingMutationRunner{}
	changes := newManualChangeSource()
	srv := &Server{
		SocketPath:     socketPath,
		Snapshotter:    NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return env.now }),
		ClockInterval:  time.Hour,
		MutationRunner: runner,
		ChangeSource:   changes,
	}
	errc := serveInBackground(t, ctx, srv, socketPath)

	conn, enc, dec := dialServe(t, socketPath)
	defer conn.Close() //nolint:errcheck
	writeRequest(t, enc, map[string]any{
		"id":     "sub",
		"method": "subscribe",
		"topics": []string{"tracker"},
	})
	assertResponseTopic(t, dec, "subscribe")
	assertEventTopic(t, dec, "tracker")

	sessionResp := sendMutation(t, socketPath, map[string]any{
		"id":     "session-color",
		"method": "recolor",
		"data": map[string]any{
			"scope":      "session",
			"session_id": "qm-demo",
			"color":      "violet",
		},
	})
	if !envelopeContains(sessionResp, `"scope":"session"`) || !envelopeContains(sessionResp, `"color":"violet"`) {
		t.Fatalf("session recolor response = %#v, want session violet", sessionResp)
	}
	if got := runner.Commands(); len(got) != 0 {
		t.Fatalf("recolor should mutate in-process, delegated commands = %#v", got)
	}
	manifest, err := env.store.Read("qm-demo")
	if err != nil {
		t.Fatalf("read recolored manifest: %v", err)
	}
	if manifest.DisplayColor() != "violet" || manifest.Display == nil || state.ParseColorStamp(manifest.Display.ColorChangedAt).IsZero() {
		t.Fatalf("manifest display after recolor = %#v, want violet with timestamp", manifest.Display)
	}
	change := topicChange(topicTracker)
	change.BroadTracker = true
	changes.Publish(change)
	readEventsUntil(t, conn, dec, 2*time.Second, func(env Envelope, seen map[string]bool) bool {
		return env.Type == "event" && env.Topic == "tracker" && envelopeContains(env, `"display_color":"violet"`)
	})

	repoResp := sendMutation(t, socketPath, map[string]any{
		"id":     "repo-color",
		"method": "recolor",
		"data": map[string]any{
			"scope":         "repo",
			"repo_identity": repoIdentity,
			"color":         "pink",
		},
	})
	if !envelopeContains(repoResp, `"scope":"repo"`) || !envelopeContains(repoResp, `"color":"pink"`) {
		t.Fatalf("repo recolor response = %#v, want repo pink", repoResp)
	}
	repoColor, ok, err := state.NewRepoColorStore(env.store.Root()).Get(repoIdentity)
	if err != nil {
		t.Fatalf("get repo color: %v", err)
	}
	if !ok || repoColor.Color != "pink" || state.ParseColorStamp(repoColor.UpdatedAt).IsZero() {
		t.Fatalf("repo color = %#v ok=%v, want pink with timestamp", repoColor, ok)
	}

	bad := sendRawMutation(t, socketPath, map[string]any{
		"id":     "bad-color",
		"method": "recolor",
		"data": map[string]any{
			"scope":      "session",
			"session_id": "qm-demo",
			"color":      "brown",
		},
	})
	if bad.Type != "response" || bad.OK == nil || *bad.OK || !strings.Contains(bad.Error, "invalid color") {
		t.Fatalf("bad color response = %#v, want invalid color error", bad)
	}

	cancel()
	if err := <-errc; err != nil {
		t.Fatalf("server returned error: %v", err)
	}
}

func TestServerReclassMutationRequiresMasterAndPersists(t *testing.T) {
	tests := []struct {
		name     string
		id       string
		class    string
		manifest state.Manifest
		wantErr  string
	}{
		{
			name:  "master",
			id:    "qm-class-master",
			class: " Wizard ",
			manifest: state.Manifest{
				SessionID: "qm-class-master",
				Agents:    []state.AgentManifest{{Name: "codex", Role: "primary"}},
			},
		},
		{
			name: "worker",
			id:   "qm-class-worker",
			manifest: state.Manifest{
				SessionID: "qm-class-worker",
				Agents:    []state.AgentManifest{{Name: "codex", Role: "primary"}},
				Extra:     map[string]json.RawMessage{"parent_session": json.RawMessage(`"qm-master"`)},
			},
			class:   "bard",
			wantErr: "workers inherit their master's class",
		},
		{
			name:     "shell",
			id:       "qm-class-shell",
			manifest: state.Manifest{SessionID: "qm-class-shell"},
			class:    "bard",
			wantErr:  "shell sessions have no class",
		},
		{
			name: "invalid class",
			id:   "qm-class-invalid",
			manifest: state.Manifest{
				SessionID: "qm-class-invalid",
				Agents:    []state.AgentManifest{{Name: "codex", Role: "primary"}},
			},
			class:   "ranger",
			wantErr: "paladin, wizard, druid, barbarian, rogue, cleric, bard",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			store, err := state.NewStore(t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			if err := store.Create(tt.manifest); err != nil {
				t.Fatal(err)
			}
			handler, ok := mutationRegistry["reclass"]
			if !ok {
				t.Fatal("reclass mutation is not registered")
			}
			response, err := handler(&Server{Snapshotter: &Snapshotter{store: store}}, context.Background(), Request{}, mutationPayload{
				SessionID: tt.id,
				Class:     tt.class,
			})
			if tt.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), tt.wantErr) {
					t.Fatalf("reclass error = %v, want %q", err, tt.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatalf("reclass: %v", err)
			}
			result, ok := response.(map[string]any)
			if !ok || result["session_id"] != tt.id || result["class"] != "wizard" || result["reclassified"] != true {
				t.Fatalf("reclass response = %#v, want normalized class response", response)
			}
			manifest, err := store.Read(tt.id)
			if err != nil {
				t.Fatal(err)
			}
			if manifest.DisplayClass() != "wizard" {
				t.Fatalf("stored class = %q, want wizard", manifest.DisplayClass())
			}
		})
	}
}

func TestServerRoleDefaultSetMutationValidatesAndPersists(t *testing.T) {
	env := seedServeFixture(t)
	socketPath := tempSocketPath(t)
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()

	runner := &recordingMutationRunner{}
	srv := &Server{
		SocketPath:     socketPath,
		Snapshotter:    NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return env.now }),
		ClockInterval:  time.Hour,
		MutationRunner: runner,
		ReasoningEfforts: func(_ context.Context, agentName, model string) []string {
			if agentName == "claude" {
				return []string{"low", "medium", "high", "xhigh", "max"}
			}
			if agentName == "codex" && model == "gpt-5.4" {
				return []string{"low", "medium", "high", "xhigh"}
			}
			return nil
		},
	}
	errc := serveInBackground(t, ctx, srv, socketPath)

	setResp := sendMutation(t, socketPath, map[string]any{
		"id":     "role-default-set",
		"method": "role_default.set",
		"data": map[string]any{
			"agent":            "claude",
			"role":             "worker",
			"model":            "claude-opus-9-unreleased",
			"reasoning_effort": "low",
		},
	})
	if !envelopeContains(setResp, `"model":"claude-opus-9-unreleased"`) || !envelopeContains(setResp, `"reasoning_effort":"low"`) {
		t.Fatalf("role_default.set response = %#v, want claude-opus-9-unreleased/low", setResp)
	}
	if got := runner.Commands(); len(got) != 0 {
		t.Fatalf("role_default.set should mutate in-process, delegated commands = %#v", got)
	}
	def, ok, err := state.NewRoleDefaultsStore(env.store.Root()).Get("claude", "worker")
	if err != nil {
		t.Fatalf("get role default: %v", err)
	}
	if !ok || def.Model != "claude-opus-9-unreleased" || def.ReasoningEffort != "low" {
		t.Fatalf("persisted role default = %+v ok=%v, want claude-opus-9-unreleased/low", def, ok)
	}

	// codex's plain gpt-5.4 does not support "max" — the reasoning effort must
	// be validated against the given model before anything is persisted.
	bad := sendRawMutation(t, socketPath, map[string]any{
		"id":     "role-default-bad-effort",
		"method": "role_default.set",
		"data": map[string]any{
			"agent":            "codex",
			"role":             "worker",
			"model":            "gpt-5.4",
			"reasoning_effort": "max",
		},
	})
	if bad.Type != "response" || bad.OK == nil || *bad.OK || !strings.Contains(bad.Error, "supported: low, medium, high, xhigh") {
		t.Fatalf("role_default.set with an unsupported effort = %#v, want a validation error", bad)
	}
	if _, ok, err := state.NewRoleDefaultsStore(env.store.Root()).Get("codex", "worker"); err != nil || ok {
		t.Fatalf("codex worker default after invalid set: ok=%v err=%v, want nothing persisted", ok, err)
	}

	// Sending both fields empty is rejected — there is no more implicit
	// clear now that Settings is the sole source of a default. The prior
	// entry must survive untouched.
	clearResp := sendRawMutation(t, socketPath, map[string]any{
		"id":     "role-default-clear",
		"method": "role_default.set",
		"data":   map[string]any{"agent": "claude", "role": "worker"},
	})
	if clearResp.Type != "response" || clearResp.OK == nil || *clearResp.OK || clearResp.Error == "" {
		t.Fatalf("role_default.set with both fields empty = %#v, want a validation error", clearResp)
	}
	if def, ok, err := state.NewRoleDefaultsStore(env.store.Root()).Get("claude", "worker"); err != nil || !ok || def.Model != "claude-opus-9-unreleased" || def.ReasoningEffort != "low" {
		t.Fatalf("claude worker default after a rejected clear: def=%+v ok=%v err=%v, want the prior entry untouched", def, ok, err)
	}

	// Removed roles are rejected rather than falling back to another bucket.
	removedRole := sendRawMutation(t, socketPath, map[string]any{
		"id":     "role-default-set-standalone",
		"method": "role_default.set",
		"data": map[string]any{
			"agent":            "claude",
			"role":             "standalone",
			"model":            "sonnet",
			"reasoning_effort": "medium",
		},
	})
	if removedRole.OK == nil || *removedRole.OK || !strings.Contains(removedRole.Error, "role is required") {
		t.Fatalf("role_default.set with a removed role = %#v, want validation error", removedRole)
	}
	if def, ok, err := state.NewRoleDefaultsStore(env.store.Root()).Get("claude", "worker"); err != nil || !ok || def.Model != "claude-opus-9-unreleased" {
		t.Fatalf("claude worker default after rejected role: def=%+v ok=%v err=%v, want prior value", def, ok, err)
	}
	if _, ok, err := state.NewRoleDefaultsStore(env.store.Root()).Get("claude", "standalone"); err != nil || ok {
		t.Fatalf("removed role default persisted: ok=%v err=%v", ok, err)
	}

	cancel()
	if err := <-errc; err != nil {
		t.Fatalf("server returned error: %v", err)
	}
}

func TestServerRoleDefaultSetClearsCarriedEffortWhenModelChanges(t *testing.T) {
	env := seedServeFixture(t)
	defaults := state.NewRoleDefaultsStore(env.store.Root())
	if err := defaults.Set("codex", "master", state.RoleDefault{Model: "gpt-6-sol", ReasoningEffort: "ultra"}); err != nil {
		t.Fatalf("seed role default: %v", err)
	}
	socketPath := tempSocketPath(t)
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	srv := &Server{
		SocketPath:     socketPath,
		Snapshotter:    NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return env.now }),
		ClockInterval:  time.Hour,
		MutationRunner: &recordingMutationRunner{},
		ReasoningEfforts: func(_ context.Context, agentName, model string) []string {
			if agentName == "codex" && model == "gpt-6-luna" {
				return []string{"low", "medium", "high", "xhigh", "max"}
			}
			return nil
		},
	}
	errC := serveInBackground(t, ctx, srv, socketPath)

	response := sendMutation(t, socketPath, map[string]any{
		"id":     "role-default-model-switch",
		"method": "role_default.set",
		"data": map[string]any{
			"agent":            "codex",
			"role":             "master",
			"model":            "gpt-6-luna",
			"reasoning_effort": "ultra",
		},
	})
	if !envelopeContains(response, `"model":"gpt-6-luna"`) || !envelopeContains(response, `"reasoning_effort":""`) {
		t.Fatalf("role_default.set model switch response = %#v, want gpt-6-luna with cleared effort", response)
	}
	if def, ok, err := defaults.Get("codex", "master"); err != nil || !ok || def.Model != "gpt-6-luna" || def.ReasoningEffort != "" {
		t.Fatalf("persisted role default = %+v ok=%v err=%v, want gpt-6-luna with cleared effort", def, ok, err)
	}
	if err := defaults.Set("codex", "worker", state.RoleDefault{Model: "gpt-6-sol", ReasoningEffort: "ultra"}); err != nil {
		t.Fatalf("seed worker role default: %v", err)
	}
	newEffort := sendRawMutation(t, socketPath, map[string]any{
		"id":     "role-default-new-invalid-effort",
		"method": "role_default.set",
		"data": map[string]any{
			"agent":            "codex",
			"role":             "worker",
			"model":            "gpt-6-luna",
			"reasoning_effort": "minimal",
		},
	})
	if newEffort.OK == nil || *newEffort.OK || !strings.Contains(newEffort.Error, "supported: low, medium, high, xhigh, max") {
		t.Fatalf("role_default.set with newly chosen invalid effort = %#v, want validation error", newEffort)
	}
	if def, ok, err := defaults.Get("codex", "worker"); err != nil || !ok || def.Model != "gpt-6-sol" || def.ReasoningEffort != "ultra" {
		t.Fatalf("worker role default = %+v ok=%v err=%v, want original value after rejection", def, ok, err)
	}

	cancel()
	if err := <-errC; err != nil {
		t.Fatalf("server returned error: %v", err)
	}
}

// TestServerRoleDefaultSetMutationMergesPartialUpdates guards a real bug:
// Set() replaces the whole persisted record, so a caller that sends only
// reasoning_effort (or only model) must not silently wipe the other,
// already-configured field. mutateRoleDefaultSet's own reasoning-effort
// validation already falls back to the persisted model when none is given —
// the write must honor that same merge, not just the validation.
func TestServerRoleDefaultSetMutationMergesPartialUpdates(t *testing.T) {
	env := seedServeFixture(t)
	socketPath := tempSocketPath(t)
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()

	srv := &Server{
		SocketPath:     socketPath,
		Snapshotter:    NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return env.now }),
		ClockInterval:  time.Hour,
		MutationRunner: &recordingMutationRunner{},
	}
	errc := serveInBackground(t, ctx, srv, socketPath)

	sendMutation(t, socketPath, map[string]any{
		"id":     "role-default-set-full",
		"method": "role_default.set",
		"data": map[string]any{
			"agent":            "codex",
			"role":             "master",
			"model":            "gpt-5.6-sol",
			"reasoning_effort": "high",
		},
	})

	effortOnlyResp := sendMutation(t, socketPath, map[string]any{
		"id":     "role-default-set-effort-only",
		"method": "role_default.set",
		"data":   map[string]any{"agent": "codex", "role": "master", "reasoning_effort": "max"},
	})
	if !envelopeContains(effortOnlyResp, `"model":"gpt-5.6-sol"`) {
		t.Fatalf("role_default.set effort-only response = %#v, want the persisted model still reported", effortOnlyResp)
	}
	if def, ok, err := state.NewRoleDefaultsStore(env.store.Root()).Get("codex", "master"); err != nil || !ok || def.Model != "gpt-5.6-sol" || def.ReasoningEffort != "max" {
		t.Fatalf("codex master after effort-only update: def=%+v ok=%v err=%v, want model unaffected and effort updated", def, ok, err)
	}

	modelOnlyResp := sendMutation(t, socketPath, map[string]any{
		"id":     "role-default-set-model-only",
		"method": "role_default.set",
		"data":   map[string]any{"agent": "codex", "role": "master", "model": "gpt-5.6-terra"},
	})
	if !envelopeContains(modelOnlyResp, `"reasoning_effort":"max"`) {
		t.Fatalf("role_default.set model-only response = %#v, want the persisted effort still reported", modelOnlyResp)
	}
	if def, ok, err := state.NewRoleDefaultsStore(env.store.Root()).Get("codex", "master"); err != nil || !ok || def.Model != "gpt-5.6-terra" || def.ReasoningEffort != "max" {
		t.Fatalf("codex master after model-only update: def=%+v ok=%v err=%v, want effort unaffected and model updated", def, ok, err)
	}

	cancel()
	if err := <-errc; err != nil {
		t.Fatalf("server returned error: %v", err)
	}
}

func TestServerRenameMutationUpdatesAndPushesTracker(t *testing.T) {
	env := seedServeFixture(t)
	if err := env.store.Update("qm-demo", func(m *state.Manifest) {
		m.SetExtra("title_provisional", "1")
	}); err != nil {
		t.Fatalf("mark title provisional: %v", err)
	}
	socketPath := tempSocketPath(t)
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()

	changes := newManualChangeSource()
	srv := &Server{
		SocketPath:    socketPath,
		Snapshotter:   NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return env.now }),
		ClockInterval: time.Hour,
		ChangeSource:  changes,
	}
	errc := serveInBackground(t, ctx, srv, socketPath)

	conn, enc, dec := dialServe(t, socketPath)
	defer conn.Close() //nolint:errcheck
	writeRequest(t, enc, map[string]any{
		"id":     "sub",
		"method": "subscribe",
		"topics": []string{"tracker"},
	})
	assertResponseTopic(t, dec, "subscribe")
	assertEventTopic(t, dec, "tracker")

	response := sendMutation(t, socketPath, map[string]any{
		"id":     "rename",
		"method": "rename",
		"data": map[string]any{
			"session_id": "qm-demo",
			"title":      "  Release triage  ",
		},
	})
	if !envelopeContains(response, `"title":"Release triage"`) {
		t.Fatalf("rename response = %#v, want trimmed title", response)
	}
	manifest, err := env.store.Read("qm-demo")
	if err != nil {
		t.Fatalf("read renamed manifest: %v", err)
	}
	if manifest.Title != "Release triage" || manifest.ExtraString("title_locked") != "1" || manifest.ExtraString("title_provisional") != "" {
		t.Fatalf("renamed manifest = %#v, want title locked and no provisional marker", manifest)
	}

	change := topicChange(topicTracker)
	change.BroadTracker = true
	changes.Publish(change)
	readEventsUntil(t, conn, dec, 2*time.Second, func(env Envelope, seen map[string]bool) bool {
		return env.Type == "event" && env.Topic == "tracker" && envelopeContains(env, `"title":"Release triage"`)
	})

	blank := sendRawMutation(t, socketPath, map[string]any{
		"id":     "blank-rename",
		"method": "rename",
		"data":   map[string]any{"session_id": "qm-demo", "title": " "},
	})
	if blank.OK == nil || *blank.OK || !strings.Contains(blank.Error, "title is required") {
		t.Fatalf("blank rename response = %#v, want title validation error", blank)
	}

	cancel()
	if err := <-errc; err != nil {
		t.Fatalf("server returned error: %v", err)
	}
}

func TestServerMutationRunnerTimeoutReturnsError(t *testing.T) {
	env := seedServeFixture(t)
	socketPath := tempSocketPath(t)
	oldTimeout := mutationOperationTimeout
	mutationOperationTimeout = 75 * time.Millisecond
	t.Cleanup(func() { mutationOperationTimeout = oldTimeout })
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()

	runner := blockingMutationRunner{started: make(chan struct{})}
	srv := &Server{
		SocketPath:     socketPath,
		Snapshotter:    NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return env.now }),
		ClockInterval:  time.Hour,
		MutationRunner: runner,
	}
	errc := serveInBackground(t, ctx, srv, socketPath)

	start := time.Now()
	got := sendRawMutation(t, socketPath, map[string]any{
		"id":     "slow",
		"method": "delete",
		"data":   map[string]any{"session_id": "qm-slow"},
	})
	if elapsed := time.Since(start); elapsed > time.Second {
		t.Fatalf("mutation response took %s, want timeout response under 1s", elapsed)
	}
	if got.Type != "response" || got.OK == nil || *got.OK || !strings.Contains(got.Error, "context deadline exceeded") {
		t.Fatalf("timeout response = %#v, want context deadline exceeded error", got)
	}

	cancel()
	if err := <-errc; err != nil {
		t.Fatalf("server returned error: %v", err)
	}
}

type serveFixture struct {
	store      *state.Store
	tmuxClient *tmux.Client
	now        time.Time
	worktree   string
}

func seedServeFixture(t *testing.T) serveFixture {
	t.Helper()

	root := filepath.Join(t.TempDir(), "state")
	worktree := filepath.Join(t.TempDir(), "worktree")
	if err := os.MkdirAll(worktree, 0o755); err != nil {
		t.Fatalf("create worktree: %v", err)
	}
	t.Setenv(state.StateRootEnv, root)
	t.Setenv("QUESTMASTER_SESSION", "qm-demo")

	store, err := state.NewStore(root)
	if err != nil {
		t.Fatalf("state store: %v", err)
	}
	m := state.Manifest{
		SessionID:   "qm-demo",
		Title:       "Serve runtime JSON",
		Cwd:         worktree,
		SessionType: "master",
		Agents:      []state.AgentManifest{{Name: "codex", Role: "agent"}},
	}
	if err := store.Create(m); err != nil {
		t.Fatalf("create manifest: %v", err)
	}

	now := time.Date(2026, 6, 19, 4, 20, 0, 0, time.UTC)
	if err := state.SaveSessionState("qm-demo", &state.SessionState{
		SessionID: "qm-demo",
		Version:   state.SchemaVersion,
		Panes: map[string]state.PaneState{
			"agent": {
				Role:         "agent",
				Agent:        "codex",
				State:        "working",
				Activity:     "Bash: go test ./...",
				LastKind:     "PreToolUse",
				LastEvent:    now.Add(-2 * time.Minute),
				WorkingSince: now.Add(-2 * time.Minute),
			},
		},
	}); err != nil {
		t.Fatalf("save session state: %v", err)
	}

	return serveFixture{
		store:      store,
		tmuxClient: tmux.NewClient(fakeTmuxRunner{sessions: "qm-demo"}),
		now:        now,
		worktree:   worktree,
	}
}

func TestSnapshotterTrackerSessionChangeIncludesLastChatAt(t *testing.T) {
	env := seedServeFixture(t)
	snap := NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return env.now })
	if _, err := snap.TrackerForChange(Change{}); err != nil {
		t.Fatalf("initial Tracker: %v", err)
	}
	chatAt := env.now.Add(-time.Second)
	if err := state.UpdateSessionState("qm-demo", func(ss *state.SessionState) bool {
		pane := ss.Panes["agent"]
		pane.LastChatAt = chatAt
		ss.Panes["agent"] = pane
		return true
	}); err != nil {
		t.Fatalf("update chat timestamp: %v", err)
	}
	got, err := snap.TrackerForChange(Change{Topics: []string{topicTracker}, SessionIDs: []string{"qm-demo"}})
	if err != nil {
		t.Fatalf("tracker change: %v", err)
	}
	if got.Sessions[0].LastChatAt == nil || !got.Sessions[0].LastChatAt.Equal(chatAt) {
		t.Fatalf("last_chat_at = %v, want %s", got.Sessions[0].LastChatAt, chatAt)
	}
}

func TestSnapshotterTrackerIncludesNarrationCastAndTypicalDuration(t *testing.T) {
	env := seedServeFixture(t)
	startedAt := env.now.Add(-time.Second)
	if err := state.UpdateSessionState("qm-demo", func(ss *state.SessionState) bool {
		pane := ss.Panes["agent"]
		pane.Narration = "It seems that something is still running."
		pane.RunningTools = []state.RunningTool{{CallID: "call-1", Tool: "Bash", Command: "go test", StartedAt: startedAt}}
		pane.Tool = "Bash"
		ss.Panes["agent"] = pane
		return true
	}); err != nil {
		t.Fatalf("update cast state: %v", err)
	}
	for _, sample := range []time.Duration{4, 6, 8} {
		if err := state.RecordToolDurationAt(env.store.Root(), "codex", "Bash", "go test", sample*time.Second); err != nil {
			t.Fatalf("record duration: %v", err)
		}
	}

	snap, err := NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return env.now }).TrackerForChange(Change{})
	if err != nil {
		t.Fatalf("tracker snapshot: %v", err)
	}
	got := snap.Sessions[0]
	if got.Narration != "It seems that something is still running." {
		t.Fatalf("narration = %q", got.Narration)
	}
	if got.Cast == nil || got.Cast.Tool != "Bash" || !got.Cast.StartedAt.Equal(startedAt) || got.Cast.TypicalMS != 6000 {
		t.Fatalf("cast = %+v, want Bash at %s with 6000ms typical", got.Cast, startedAt)
	}
}

func TestStoppedTrackerRowsCopyOnlyNarrationFromSessionState(t *testing.T) {
	env := seedServeFixture(t)
	lastChatAt := env.now.Add(-time.Minute)
	if err := state.UpdateSessionState("qm-demo", func(ss *state.SessionState) bool {
		pane := ss.Panes["agent"]
		pane.State = "working"
		pane.Activity = "stale state activity"
		pane.LastKind = "PreToolUse"
		pane.LastEvent = env.now.Add(-time.Minute)
		pane.WorkingSince = env.now.Add(-time.Minute)
		pane.LastChatAt = lastChatAt
		pane.Narration = "latest narration"
		pane.RunningTools = []state.RunningTool{{Tool: "Bash", StartedAt: env.now.Add(-time.Minute)}}
		ss.Panes["agent"] = pane
		return true
	}); err != nil {
		t.Fatalf("seed stopped session state: %v", err)
	}
	assertStopped := func(path string, row SessionSnapshot) {
		t.Helper()
		if row.Status != "stopped" || row.State != "stopped" || row.Narration != "latest narration" {
			t.Fatalf("%s stopped row state/narration = %#v", path, row)
		}
		if row.ElapsedMS != 0 || row.ElapsedSince != nil || row.LatestActivity != "" || row.LastKind != "" || row.LastChatAt != nil || row.Cast != nil {
			t.Fatalf("%s stopped row retained live state: %#v", path, row)
		}
	}

	full := NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return env.now })
	full.fetcher = func(tracker.SessionInfo) (tracker.TrackerSnapshot, error) {
		return tracker.TrackerSnapshot{ObservedAt: env.now, Sessions: []tracker.SessionRow{{ID: "qm-demo", Status: "stopped", State: "stopped"}}}, nil
	}
	got, err := full.TrackerForChange(Change{BroadTracker: true})
	if err != nil {
		t.Fatalf("full stopped snapshot: %v", err)
	}
	assertStopped("full refresh", got.Sessions[0])

	incremental := NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return env.now })
	incremental.fetcher = func(tracker.SessionInfo) (tracker.TrackerSnapshot, error) {
		return tracker.TrackerSnapshot{ObservedAt: env.now, Sessions: []tracker.SessionRow{{ID: "qm-demo", Status: "active", Agent: "codex"}}}, nil
	}
	if _, err := incremental.TrackerForChange(Change{}); err != nil {
		t.Fatalf("initial active snapshot: %v", err)
	}
	incremental.tmuxClient = tmux.NewClient(fakeTmuxRunner{})
	got, err = incremental.TrackerForChange(Change{Topics: []string{topicTracker}, SessionIDs: []string{"qm-demo"}})
	if err != nil {
		t.Fatalf("incremental stopped snapshot: %v", err)
	}
	assertStopped("incremental update", got.Sessions[0])
}

func TestCastSnapshotUsesCommandThenToolMedianFallback(t *testing.T) {
	t.Parallel()
	result := sessionactivity.Result{
		Agent:       "claude",
		RunningTool: &state.RunningTool{Tool: "Bash", Command: "sleep"},
	}
	commandKey := state.ToolDurationKey{Agent: "claude", Tool: "Bash", Command: "sleep"}
	toolKey := state.ToolDurationKey{Agent: "claude", Tool: "Bash"}
	for _, tc := range []struct {
		name     string
		typicals map[state.ToolDurationKey]int64
		want     int64
	}{
		{name: "command median preferred", typicals: map[state.ToolDurationKey]int64{commandKey: 15000, toolKey: 400}, want: 15000},
		{name: "tool median fallback", typicals: map[state.ToolDurationKey]int64{toolKey: 400}, want: 400},
		{name: "no trained median", typicals: map[state.ToolDurationKey]int64{}, want: 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			if got := castSnapshot(result, "", tc.typicals).TypicalMS; got != tc.want {
				t.Fatalf("typical_ms = %d, want %d", got, tc.want)
			}
		})
	}
}

func makeTestRepo(t *testing.T, name string) (string, string) {
	t.Helper()
	root := filepath.Join(t.TempDir(), name)
	gitDir := filepath.Join(root, ".git")
	if err := os.MkdirAll(gitDir, 0o755); err != nil {
		t.Fatalf("create git dir: %v", err)
	}
	projectID, err := filepath.EvalSymlinks(gitDir)
	if err != nil {
		t.Fatalf("resolve git dir: %v", err)
	}
	return filepath.Dir(projectID), projectID
}

func tempSocketPath(t *testing.T) string {
	t.Helper()
	path := filepath.Join(os.TempDir(), fmt.Sprintf("qm-serve-test-%d.sock", time.Now().UnixNano()))
	t.Cleanup(func() { os.Remove(path) }) //nolint:errcheck
	return path
}

func serveInBackground(t *testing.T, ctx context.Context, srv *Server, socketPath string) <-chan error {
	t.Helper()
	errc := make(chan error, 1)
	go func() { errc <- srv.Serve(ctx) }()
	waitForSocket(t, socketPath)
	return errc
}

func waitForSocket(t *testing.T, path string) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		conn, err := net.Dial("unix", path)
		if err == nil {
			conn.Close() //nolint:errcheck
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("socket %s did not become ready", path)
}

func writeRequest(t *testing.T, enc *json.Encoder, req map[string]any) {
	t.Helper()
	if err := enc.Encode(req); err != nil {
		t.Fatalf("write request: %v", err)
	}
}

func writeWatchTestSessionState(root, sessionID, activity string) error {
	now := time.Now().UTC()
	dir := state.SessionStateDir(root, sessionID)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("create session state dir: %w", err)
	}
	body, err := json.Marshal(state.SessionState{
		SessionID: sessionID,
		Version:   state.SchemaVersion,
		SeenAt:    now,
		Panes: map[string]state.PaneState{
			"agent": {
				Role:      "agent",
				Agent:     "codex",
				State:     "blocked",
				Activity:  activity,
				LastKind:  "Probe",
				LastEvent: now,
				Seq:       now.UnixNano(),
			},
		},
	})
	if err != nil {
		return fmt.Errorf("marshal session state: %w", err)
	}
	path := state.SessionStatePath(root, sessionID)
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, append(body, '\n'), 0o644); err != nil {
		return fmt.Errorf("write tmp session state: %w", err)
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return fmt.Errorf("rename session state: %w", err)
	}
	return nil
}

func assertResponseTopic(t *testing.T, dec *json.Decoder, topic string) Envelope {
	t.Helper()
	var env Envelope
	if err := dec.Decode(&env); err != nil {
		t.Fatalf("decode response %s: %v", topic, err)
	}
	if env.Type != "response" || env.Topic != topic || env.OK == nil || !*env.OK {
		t.Fatalf("response = %#v, want ok %s response", env, topic)
	}
	return env
}

func assertEventTopic(t *testing.T, dec *json.Decoder, topic string) Envelope {
	t.Helper()
	var env Envelope
	if err := dec.Decode(&env); err != nil {
		t.Fatalf("decode event %s: %v", topic, err)
	}
	if env.Type != "event" || env.Topic != topic {
		t.Fatalf("event = %#v, want %s event", env, topic)
	}
	return env
}

func stringList(value any) []string {
	raw, ok := value.([]any)
	if !ok {
		return nil
	}
	out := make([]string, 0, len(raw))
	for _, item := range raw {
		if s, ok := item.(string); ok {
			out = append(out, s)
		}
	}
	return out
}

func stringListContains(values []string, target string) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}

func sendMutation(t *testing.T, socketPath string, req map[string]any) Envelope {
	t.Helper()
	env := sendRawMutation(t, socketPath, req)
	if env.Type != "response" || env.OK == nil || !*env.OK {
		t.Fatalf("mutation response = %#v, want ok", env)
	}
	return env
}

func sendRawMutation(t *testing.T, socketPath string, req map[string]any) Envelope {
	t.Helper()
	conn, enc, dec := dialServe(t, socketPath)
	defer conn.Close() //nolint:errcheck
	writeRequest(t, enc, req)
	var env Envelope
	if err := dec.Decode(&env); err != nil {
		t.Fatalf("decode mutation response: %v", err)
	}
	return env
}

type recordedMutationCommand struct {
	Args  []string
	Stdin string
}

type recordingMutationRunner struct {
	mu       sync.Mutex
	commands []recordedMutationCommand
	err      error
}

func (r *recordingMutationRunner) RunMutationCommand(_ context.Context, args []string, stdin []byte) ([]byte, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.commands = append(r.commands, recordedMutationCommand{
		Args:  append([]string(nil), args...),
		Stdin: string(stdin),
	})
	if r.err != nil {
		return nil, r.err
	}
	return []byte(`{"delegated":true}`), nil
}

func (r *recordingMutationRunner) Reset() {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.commands = nil
}

func (r *recordingMutationRunner) Commands() []recordedMutationCommand {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]recordedMutationCommand, len(r.commands))
	copy(out, r.commands)
	return out
}

type blockingMutationRunner struct {
	started chan struct{}
}

func (r blockingMutationRunner) RunMutationCommand(ctx context.Context, _ []string, _ []byte) ([]byte, error) {
	close(r.started)
	<-ctx.Done()
	return nil, ctx.Err()
}

type recordingTmuxRunner struct {
	mu    sync.Mutex
	calls [][]string
}

func (r *recordingTmuxRunner) Run(_ context.Context, args ...string) (string, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.calls = append(r.calls, append([]string(nil), args...))
	return "", nil
}

func (r *recordingTmuxRunner) Calls() [][]string {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([][]string, len(r.calls))
	for i := range r.calls {
		out[i] = append([]string(nil), r.calls[i]...)
	}
	return out
}

func dialServe(t *testing.T, socketPath string) (net.Conn, *json.Encoder, *json.Decoder) {
	t.Helper()
	conn, err := net.Dial("unix", socketPath)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	return conn, json.NewEncoder(conn), json.NewDecoder(conn)
}

func updateSessionActivity(t *testing.T, now time.Time) {
	t.Helper()
	if err := state.UpdateSessionState("qm-demo", func(ss *state.SessionState) bool {
		pane := ss.Panes["agent"]
		pane.State = "blocked"
		pane.Activity = "Question: approve?"
		pane.LastKind = "Notification"
		pane.LastEvent = now.Add(-time.Minute)
		pane.WorkingSince = time.Time{}
		ss.Panes["agent"] = pane
		return true
	}); err != nil {
		t.Fatalf("update session activity: %v", err)
	}
}

func readEventsUntil(t *testing.T, conn net.Conn, dec *json.Decoder, timeout time.Duration, done func(Envelope, map[string]bool) bool) map[string]bool {
	t.Helper()
	seen := map[string]bool{}
	if err := conn.SetReadDeadline(time.Now().Add(timeout)); err != nil {
		t.Fatalf("set deadline: %v", err)
	}
	defer conn.SetReadDeadline(time.Time{}) //nolint:errcheck

	for {
		var env Envelope
		if err := dec.Decode(&env); err != nil {
			if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
				t.Fatalf("timed out waiting for event; saw %v", seen)
			}
			t.Fatalf("decode event: %v; saw %v", err, seen)
		}
		if env.Type == "event" {
			seen[env.Topic] = true
		}
		if done(env, seen) {
			return seen
		}
	}
}

func assertNoEvent(t *testing.T, conn net.Conn, dec *json.Decoder, timeout time.Duration) {
	t.Helper()
	if err := conn.SetReadDeadline(time.Now().Add(timeout)); err != nil {
		t.Fatalf("set deadline: %v", err)
	}
	defer conn.SetReadDeadline(time.Time{}) //nolint:errcheck
	var env Envelope
	if err := dec.Decode(&env); err == nil && env.Type == "event" {
		t.Fatalf("unexpected event after idle change: %#v", env)
	}
}

func envelopeContains(env Envelope, needle string) bool {
	raw, _ := json.Marshal(env.Data)
	return strings.Contains(string(raw), needle)
}
