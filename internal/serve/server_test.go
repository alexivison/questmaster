//go:build linux || darwin

package serve

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/dirsuggest"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tracker"
	"github.com/fsnotify/fsnotify"
)

type fakeTmuxRunner struct {
	sessions string
}

func (r fakeTmuxRunner) Run(context.Context, ...string) (string, error) {
	return r.sessions, nil
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
		Panes:     map[string]state.PaneState{"primary": {Role: "primary", State: "working"}},
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
		pane := ss.Panes["primary"]
		pane.Activity = "UserPromptSubmit"
		ss.Panes["primary"] = pane
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
				ID:           "qm-demo",
				Title:        "Serve runtime JSON",
				Status:       "active",
				SessionType:  "standalone",
				PrimaryAgent: "codex",
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
	if initial.Sessions[0].PrimaryAgent != "" {
		t.Fatalf("initial primary_agent = %q, want empty shell row", initial.Sessions[0].PrimaryAgent)
	}

	repoRoot := filepath.Join(t.TempDir(), "adopted")
	if err := os.MkdirAll(filepath.Join(repoRoot, ".git"), 0o755); err != nil {
		t.Fatalf("create adopted repo: %v", err)
	}
	if err := env.store.Update("qm-demo", func(m *state.Manifest) {
		m.Cwd = repoRoot
		m.Agents = []state.AgentManifest{{Name: "claude", Role: "primary", CLI: "claude"}}
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
	if row.PrimaryAgent != "claude" {
		t.Fatalf("primary_agent = %q, want claude", row.PrimaryAgent)
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
				SessionType:  "standalone",
				PrimaryAgent: "codex",
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
		pane := ss.Panes["primary"]
		pane.State = "done"
		pane.Activity = "Finished"
		pane.LastKind = "Stop"
		pane.LastEvent = now.Add(-state.DoneToIdleGrace + time.Second)
		pane.WorkingSince = time.Time{}
		ss.Panes["primary"] = pane
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
		SessionType: "standalone",
		Agents:      []state.AgentManifest{{Name: "codex", Role: "primary"}},
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
			name: "relay",
			request: map[string]any{
				"id":     "relay",
				"method": "relay",
				"data":   map[string]any{"worker_id": "qm-worker", "message": "investigate"},
			},
			wantArgs:  []string{"relay", "qm-worker", "--message-file", "-"},
			wantStdin: "investigate",
		},
		{
			name: "broadcast",
			request: map[string]any{
				"id":     "broadcast",
				"method": "broadcast",
				"data":   map[string]any{"master_id": "qm-master", "message": "take stock"},
			},
			wantArgs:  []string{"broadcast", "--message-file", "-", "--", "qm-master"},
			wantStdin: "take stock",
		},
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
					"primary":   "codex",
					"prompt":    "work this",
				},
			},
			wantArgs:  []string{"spawn", "--from-app", "--cwd", "/tmp/worker", "--primary", "codex", "--prompt-file", "-", "--", "qm-master", "worker title"},
			wantStdin: "work this",
		},
		{
			name: "start",
			request: map[string]any{
				"id":     "start",
				"method": "start",
				"data": map[string]any{
					"title":   "session title",
					"cwd":     "/tmp/project",
					"primary": "codex",
					"color":   "violet",
					"prompt":  "start this",
					"master":  "true",
				},
			},
			wantArgs:  []string{"start", "--from-app", "--cwd", "/tmp/project", "--primary", "codex", "--color", "violet", "--master", "--prompt-file", "-", "--", "session title"},
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
	for _, method := range []string{"mutate", "unknown", "mutation.unknown", "tracker"} {
		if isMutationMethod(method) {
			t.Fatalf("unregistered method %q routed as mutation", method)
		}
	}
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
		DirQuerier: dirsuggest.DirQuerierFunc(func(query string) ([]string, error) {
			gotQuery = query
			return []string{"/tmp/not-a-match", "/tmp/project-app", "/tmp/project-log"}, nil
		}),
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

func TestServerSwitchMutationUsesLocalTmuxAction(t *testing.T) {
	env := seedServeFixture(t)
	socketPath := tempSocketPath(t)
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()

	runner := &recordingTmuxRunner{}
	srv := &Server{
		SocketPath:    socketPath,
		Snapshotter:   NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return env.now }),
		ClockInterval: time.Hour,
		TmuxClient:    tmux.NewClient(runner),
	}
	errc := serveInBackground(t, ctx, srv, socketPath)

	envResp := sendMutation(t, socketPath, map[string]any{
		"id":     "switch",
		"method": "switch",
		"data":   map[string]any{"session_id": "qm-demo"},
	})
	if envResp.Type != "response" || envResp.OK == nil || !*envResp.OK || !envelopeContains(envResp, `"switched":true`) {
		t.Fatalf("switch response = %#v, want ok switched", envResp)
	}
	calls := runner.Calls()
	if len(calls) != 1 || !reflect.DeepEqual(calls[0], []string{"switch-client", "-t", "qm-demo"}) {
		t.Fatalf("tmux calls = %#v, want switch-client to qm-demo", calls)
	}

	badResp := sendRawMutation(t, socketPath, map[string]any{
		"id":     "bad-switch",
		"method": "switch",
		"data":   map[string]any{"session_id": "../qm-demo"},
	})
	if badResp.Type != "response" || badResp.OK == nil || *badResp.OK || !strings.Contains(badResp.Error, "invalid session_id") {
		t.Fatalf("bad switch response = %#v, want invalid session_id error", badResp)
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

func TestServerMutationValidationErrorEnvelope(t *testing.T) {
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

	got := sendRawMutation(t, socketPath, map[string]any{
		"id":     "bad",
		"method": "relay",
		"data":   map[string]any{"worker_id": "qm-worker"},
	})
	if got.Type != "response" || got.OK == nil || *got.OK || !strings.Contains(got.Error, "message is required") {
		t.Fatalf("validation response = %#v, want message required error", got)
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
		SessionType: "standalone",
		Agents:      []state.AgentManifest{{Name: "codex", Role: "primary"}},
	}
	if err := store.Create(m); err != nil {
		t.Fatalf("create manifest: %v", err)
	}

	now := time.Date(2026, 6, 19, 4, 20, 0, 0, time.UTC)
	if err := state.SaveSessionState("qm-demo", &state.SessionState{
		SessionID: "qm-demo",
		Version:   state.SchemaVersion,
		Panes: map[string]state.PaneState{
			"primary": {
				Role:         "primary",
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
			"primary": {
				Role:      "primary",
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
		pane := ss.Panes["primary"]
		pane.State = "blocked"
		pane.Activity = "Question: approve?"
		pane.LastKind = "Notification"
		pane.LastEvent = now.Add(-time.Minute)
		pane.WorkingSince = time.Time{}
		ss.Panes["primary"] = pane
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
