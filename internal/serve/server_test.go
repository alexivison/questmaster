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
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/dirsuggest"
	"github.com/alexivison/questmaster/internal/quests/gate"
	"github.com/alexivison/questmaster/internal/quests/quest"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tracker"
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

type countingQuestStore struct {
	*quest.FileStore
	mu        sync.Mutex
	listCount int
	loadedIDs []string
}

func (s *countingQuestStore) List() ([]quest.Quest, error) {
	s.mu.Lock()
	s.listCount++
	s.mu.Unlock()
	return s.FileStore.List()
}

func (s *countingQuestStore) Load(id string) (*quest.Quest, error) {
	s.mu.Lock()
	s.loadedIDs = append(s.loadedIDs, id)
	s.mu.Unlock()
	return s.FileStore.Load(id)
}

func (s *countingQuestStore) ListCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.listCount
}

func (s *countingQuestStore) LoadedIDs() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.loadedIDs...)
}

type manualChangeSource struct {
	ch chan Change
}

func newManualChangeSource() *manualChangeSource {
	return &manualChangeSource{ch: make(chan Change, 16)}
}

func (s *manualChangeSource) Subscribe(ctx context.Context) (<-chan Change, func()) {
	var once sync.Once
	unsubscribe := func() {
		once.Do(func() {})
	}
	go func() {
		<-ctx.Done()
		unsubscribe()
	}()
	return s.ch, unsubscribe
}

func (s *manualChangeSource) Close() error { return nil }

func (s *manualChangeSource) Publish(change Change) {
	s.ch <- change
}

func TestSnapshotterSurfacesBoardTrackerAndQuest(t *testing.T) {
	env := seedServeFixture(t)
	snap := NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return env.now })

	board, err := snap.Board(t.Context())
	if err != nil {
		t.Fatalf("Board: %v", err)
	}
	if len(board.Groups) != 1 || board.Groups[0].Repo != "questmaster" {
		t.Fatalf("board groups = %#v, want one questmaster group", board.Groups)
	}
	if got := board.Groups[0].Quests[0].Runtime.Sessions; len(got) != 1 || got[0] != "qm-demo" {
		t.Fatalf("board runtime sessions = %v, want [qm-demo]", got)
	}
	if got := board.Groups[0].Quests[0].Runtime.SessionDetails; len(got) != 1 || got[0].ID != "qm-demo" {
		t.Fatalf("board runtime session_details = %#v, want qm-demo", got)
	}
	if got := board.Groups[0].Quests[0].Runtime.Adventurers; len(got) != 1 || got[0].ID != "qm-demo" {
		t.Fatalf("board runtime legacy adventurers = %#v, want qm-demo compatibility field", got)
	}

	tracker, err := snap.Tracker(t.Context())
	if err != nil {
		t.Fatalf("Tracker: %v", err)
	}
	if tracker.Current == nil || tracker.Current.ID != "qm-demo" {
		t.Fatalf("tracker current = %#v, want qm-demo", tracker.Current)
	}
	if len(tracker.Sessions) != 1 {
		t.Fatalf("tracker sessions = %d, want 1", len(tracker.Sessions))
	}
	row := tracker.Sessions[0]
	if row.Status != "active" || row.State != "working" || row.LatestActivity != "Bash: go test ./..." {
		t.Fatalf("tracker row = %#v, want active working with latest activity", row)
	}
	if row.WorktreePath != env.worktree || row.QuestID != "DEMO-1" || row.QuestLoop == nil {
		t.Fatalf("tracker row quest/worktree = %#v", row)
	}

	detail, err := snap.Quest(t.Context(), "DEMO-1")
	if err != nil {
		t.Fatalf("Quest: %v", err)
	}
	if detail.Quest.Title != "Serve runtime JSON" || detail.Runtime.Gates["tests"] != "fail" {
		t.Fatalf("quest detail = %#v", detail)
	}
}

func TestSnapshotterTrackerSessionChangeProjectsArtifacts(t *testing.T) {
	env := seedServeFixture(t)
	snap := NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return env.now })
	if _, err := snap.Tracker(t.Context()); err != nil {
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
		QuestID:   "DEMO-1",
		Panes:     map[string]state.PaneState{"primary": {Role: "primary", State: "working"}},
	}); err != nil {
		t.Fatalf("old hook rewrite: %v", err)
	}

	tracker, err := snap.TrackerForChange(Change{Topics: []string{topicTracker}, SessionIDs: []string{"qm-demo"}})
	if err != nil {
		t.Fatalf("TrackerForChange: %v", err)
	}
	if len(tracker.Sessions) != 1 {
		t.Fatalf("tracker sessions = %d, want 1", len(tracker.Sessions))
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
}

func TestServerSocketReadsAndPushesUpdates(t *testing.T) {
	env := seedServeFixture(t)
	socketPath := filepath.Join(os.TempDir(), fmt.Sprintf("qm-serve-test-%d.sock", time.Now().UnixNano()))
	t.Cleanup(func() { os.Remove(socketPath) }) //nolint:errcheck
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()

	srv := &Server{
		SocketPath:    socketPath,
		Snapshotter:   NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return env.now }),
		ClockInterval: time.Hour,
	}
	errc := make(chan error, 1)
	go func() { errc <- srv.Serve(ctx) }()
	waitForSocket(t, socketPath)

	conn, err := net.Dial("unix", socketPath)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close() //nolint:errcheck
	enc := json.NewEncoder(conn)
	dec := json.NewDecoder(conn)

	writeRequest(t, enc, map[string]any{"id": "1", "method": "board"})
	assertResponseTopic(t, dec, "board")
	writeRequest(t, enc, map[string]any{"id": "2", "method": "tracker"})
	assertResponseTopic(t, dec, "tracker")
	writeRequest(t, enc, map[string]any{"id": "3", "method": "quest", "quest_id": "DEMO-1"})
	assertResponseTopic(t, dec, "quest")

	writeRequest(t, enc, map[string]any{
		"id":       "4",
		"method":   "subscribe",
		"topics":   []string{"board", "tracker", "quest"},
		"quest_id": "DEMO-1",
	})
	assertResponseTopic(t, dec, "subscribe")
	for _, want := range []string{"board", "tracker", "quest"} {
		assertEventTopic(t, dec, want)
	}

	updateSessionActivity(t, env.now)

	matchedBoard := false
	seen := readEventsUntil(t, conn, dec, 2*time.Second, func(env Envelope, seen map[string]bool) bool {
		if env.Type == "event" && env.Topic == "board" && envelopeContains(env, "blocked") {
			matchedBoard = true
		}
		return matchedBoard && seen["board"] && seen["tracker"] && seen["quest"]
	})
	for _, want := range []string{"board", "tracker", "quest"} {
		if !seen[want] {
			t.Fatalf("file-watch events = %v, missing %s", seen, want)
		}
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
	errc := make(chan error, 1)
	go func() { errc <- srv.Serve(ctx) }()
	waitForSocket(t, socketPath)

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

func TestSnapshotterBoardSkipsQuestListWhenFingerprintUnchanged(t *testing.T) {
	env := seedServeFixture(t)
	store := &countingQuestStore{FileStore: quest.DefaultStore()}
	snap := NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return env.now })
	snap.questStore = store

	if _, err := snap.Board(t.Context()); err != nil {
		t.Fatalf("first Board: %v", err)
	}
	if _, err := snap.Board(t.Context()); err != nil {
		t.Fatalf("second Board: %v", err)
	}

	if got := store.ListCount(); got != 1 {
		t.Fatalf("quest List calls = %d, want 1 with unchanged fingerprint", got)
	}
}

func TestSnapshotterBoardReloadsOnlyChangedQuestFromChangeIDs(t *testing.T) {
	env := seedServeFixture(t)
	if err := quest.DefaultStore().Save(&quest.Quest{
		ID:      "DEMO-2",
		Title:   "Unchanged quest",
		Status:  quest.StatusActive,
		Summary: "second",
		Project: "questmaster",
		Body:    []quest.Block{{Type: quest.BlockText, Text: "Second"}},
	}); err != nil {
		t.Fatalf("save second quest: %v", err)
	}
	store := &countingQuestStore{FileStore: quest.DefaultStore()}
	snap := NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return env.now })
	snap.questStore = store

	if _, err := snap.Board(t.Context()); err != nil {
		t.Fatalf("initial Board: %v", err)
	}
	q, err := quest.DefaultStore().Load("DEMO-1")
	if err != nil {
		t.Fatalf("load quest for update: %v", err)
	}
	q.Title = "Incremental title"
	if err := quest.DefaultStore().Save(q); err != nil {
		t.Fatalf("save changed quest: %v", err)
	}

	board, err := snap.BoardForChange(questChange("DEMO-1", topicBoard, topicQuest))
	if err != nil {
		t.Fatalf("incremental Board: %v", err)
	}
	if got := store.ListCount(); got != 1 {
		t.Fatalf("quest List calls = %d, want only the initial full list", got)
	}
	if got := store.LoadedIDs(); !reflect.DeepEqual(got, []string{"DEMO-1"}) {
		t.Fatalf("quest Load ids = %v, want only DEMO-1", got)
	}
	if !boardContainsQuestTitle(board, "Incremental title") {
		t.Fatalf("incremental board missing changed title: %#v", board.Groups)
	}
}

func TestSnapshotterTrackerCachesTmuxListSessions(t *testing.T) {
	env := seedServeFixture(t)
	runner := &countingTmuxRunner{sessions: "qm-demo"}
	snap := NewSnapshotter(env.store, tmux.NewClient(runner), func() time.Time { return env.now })

	if _, err := snap.Tracker(t.Context()); err != nil {
		t.Fatalf("first Tracker: %v", err)
	}
	if _, err := snap.Tracker(t.Context()); err != nil {
		t.Fatalf("second Tracker: %v", err)
	}
	if got := runner.Count("list-sessions"); got != 1 {
		t.Fatalf("list-sessions calls = %d, want cached single call", got)
	}
	snap.Invalidate(Change{Topics: []string{topicTracker}, SessionIDs: []string{"qm-demo"}})
	if _, err := snap.Tracker(t.Context()); err != nil {
		t.Fatalf("Tracker after invalidate: %v", err)
	}
	if got := runner.Count("list-sessions"); got != 2 {
		t.Fatalf("list-sessions calls after invalidate = %d, want 2", got)
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
				QuestID:      "DEMO-1",
				QuestTitle:   "Serve runtime JSON",
			}},
		}, nil
	}

	if _, err := snap.Tracker(t.Context()); err != nil {
		t.Fatalf("initial Tracker: %v", err)
	}
	updateSessionActivity(t, env.now)
	tracker, err := snap.TrackerForChange(Change{Topics: []string{topicTracker}, SessionIDs: []string{"qm-demo"}})
	if err != nil {
		t.Fatalf("incremental Tracker: %v", err)
	}

	if fetches != 1 {
		t.Fatalf("full tracker fetches = %d, want only initial fetch", fetches)
	}
	if len(tracker.Sessions) != 1 || tracker.Sessions[0].State != "blocked" || tracker.Sessions[0].LatestActivity != "Question: approve?" {
		t.Fatalf("incremental tracker row = %#v, want blocked Question activity", tracker.Sessions)
	}
}

func TestSnapshotterTrackerIncrementalSessionChangeRefreshesTmuxLiveness(t *testing.T) {
	env := seedServeFixture(t)
	runner := &countingTmuxRunner{sessions: "qm-demo"}
	snap := NewSnapshotter(env.store, tmux.NewClient(runner), func() time.Time { return env.now })
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
				QuestID:      "DEMO-1",
				QuestTitle:   "Serve runtime JSON",
			}},
		}, nil
	}

	if _, err := snap.Tracker(t.Context()); err != nil {
		t.Fatalf("initial Tracker: %v", err)
	}
	runner.sessions = ""
	change := Change{Topics: []string{topicTracker}, SessionIDs: []string{"qm-demo"}}
	snap.Invalidate(change)
	tracker, err := snap.TrackerForChange(change)
	if err != nil {
		t.Fatalf("incremental Tracker: %v", err)
	}

	if fetches != 1 {
		t.Fatalf("full tracker fetches = %d, want only initial fetch", fetches)
	}
	if got := runner.Count("list-sessions"); got != 1 {
		t.Fatalf("list-sessions calls = %d, want one liveness refresh", got)
	}
	if len(tracker.Sessions) != 1 || tracker.Sessions[0].Status != "stopped" || tracker.Sessions[0].State != "stopped" || tracker.Sessions[0].ElapsedMS != 0 {
		t.Fatalf("incremental stopped row = %#v, want stopped with zero elapsed", tracker.Sessions)
	}
}

func TestSnapshotterClockReconcilesMissedStateWrite(t *testing.T) {
	env := seedServeFixture(t)
	now := time.Now().UTC()
	snap := NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return now })

	initial, err := snap.Tracker(t.Context())
	if err != nil {
		t.Fatalf("initial Tracker: %v", err)
	}
	if len(initial.Sessions) != 1 || initial.Sessions[0].State != "working" {
		t.Fatalf("initial tracker state = %#v, want working", initial.Sessions)
	}

	lastEvent := now
	if err := state.UpdateSessionState("qm-demo", func(ss *state.SessionState) bool {
		pane := ss.Panes["primary"]
		pane.State = "done"
		pane.Activity = "Finished after missed watch event"
		pane.LastKind = "Stop"
		pane.LastEvent = lastEvent
		pane.WorkingSince = time.Time{}
		ss.Panes["primary"] = pane
		return true
	}); err != nil {
		t.Fatalf("write missed state update: %v", err)
	}

	now = lastEvent.Add(time.Second)
	tracker, err := snap.TrackerForChange(clockChange())
	if err != nil {
		t.Fatalf("clock Tracker: %v", err)
	}
	if len(tracker.Sessions) != 1 || tracker.Sessions[0].State != "done" || tracker.Sessions[0].LatestActivity != "Finished after missed watch event" {
		t.Fatalf("clock tracker row = %#v, want reconciled done state", tracker.Sessions)
	}
}

func TestServerPushChangedKeepsTrackerIncrementalAfterInvalidate(t *testing.T) {
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
				QuestID:      "DEMO-1",
				QuestTitle:   "Serve runtime JSON",
			}},
		}, nil
	}
	srv := &Server{Snapshotter: snap}
	last := map[string][]byte{}
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)

	if err := srv.pushChanged(t.Context(), enc, []string{topicTracker}, "", last, allTopicsChange()); err != nil {
		t.Fatalf("initial pushChanged: %v", err)
	}
	if fetches != 1 {
		t.Fatalf("initial full tracker fetches = %d, want 1", fetches)
	}

	updateSessionActivity(t, env.now)
	buf.Reset()
	if err := srv.pushChanged(t.Context(), enc, []string{topicTracker}, "", last, Change{
		Topics:     []string{topicTracker},
		SessionIDs: []string{"qm-demo"},
	}); err != nil {
		t.Fatalf("incremental pushChanged: %v", err)
	}
	if fetches != 1 {
		t.Fatalf("full tracker fetches after session change = %d, want production push to stay incremental", fetches)
	}
	if !strings.Contains(buf.String(), "Question: approve?") {
		t.Fatalf("incremental push output = %s, want updated activity", buf.String())
	}
}

func TestMergeChangesCoalescesTopicsAndIDs(t *testing.T) {
	got := mergeChanges(
		Change{Topics: []string{topicBoard}, QuestIDs: []string{"DEMO-1"}, SessionIDs: []string{"qm-one"}},
		Change{Topics: []string{topicBoard, topicQuest}, QuestIDs: []string{"DEMO-2", "DEMO-1"}, SessionIDs: []string{"qm-two"}},
	)
	if !reflect.DeepEqual(got.Topics, []string{topicBoard, topicQuest}) {
		t.Fatalf("merged topics = %v", got.Topics)
	}
	if !reflect.DeepEqual(got.QuestIDs, []string{"DEMO-1", "DEMO-2"}) {
		t.Fatalf("merged quest ids = %v", got.QuestIDs)
	}
	if !reflect.DeepEqual(got.SessionIDs, []string{"qm-one", "qm-two"}) {
		t.Fatalf("merged session ids = %v", got.SessionIDs)
	}
}

func TestFileChangeSourceBurstFlushesAtMaxWait(t *testing.T) {
	t.Parallel()

	const sessionID = "qm-burst"
	root := filepath.Join(t.TempDir(), "state")
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

func TestServerClockChangeWithoutStateTransitionProducesNoWirePush(t *testing.T) {
	env := seedServeFixture(t)
	socketPath := filepath.Join(os.TempDir(), fmt.Sprintf("qm-serve-test-%d.sock", time.Now().UnixNano()))
	t.Cleanup(func() { os.Remove(socketPath) }) //nolint:errcheck
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()

	changes := newManualChangeSource()
	srv := &Server{
		SocketPath:    socketPath,
		Snapshotter:   NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return env.now }),
		ClockInterval: time.Hour,
		ChangeSource:  changes,
	}
	errc := make(chan error, 1)
	go func() { errc <- srv.Serve(ctx) }()
	waitForSocket(t, socketPath)

	conn, enc, dec := dialServe(t, socketPath)
	defer conn.Close() //nolint:errcheck
	writeRequest(t, enc, map[string]any{
		"id":       "sub",
		"method":   "subscribe",
		"topics":   []string{"board", "tracker", "quest"},
		"quest_id": "DEMO-1",
	})
	assertResponseTopic(t, dec, "subscribe")
	for _, want := range []string{"board", "tracker", "quest"} {
		assertEventTopic(t, dec, want)
	}

	changes.Publish(clockChange())
	assertNoEvent(t, conn, dec, 250*time.Millisecond)

	cancel()
	if err := <-errc; err != nil {
		t.Fatalf("server returned error: %v", err)
	}
}

func TestServerClockChangeClearsStaleDoneTrackerState(t *testing.T) {
	env := seedServeFixture(t)
	now := time.Now().UTC()
	lastEvent := now.Add(-(state.DoneToIdleGrace / 2))
	if err := state.UpdateSessionState("qm-demo", func(ss *state.SessionState) bool {
		pane := ss.Panes["primary"]
		pane.State = "done"
		pane.Activity = "Finished"
		pane.LastKind = "Stop"
		pane.LastEvent = lastEvent
		pane.WorkingSince = time.Time{}
		ss.Panes["primary"] = pane
		return true
	}); err != nil {
		t.Fatalf("seed done state: %v", err)
	}

	socketPath := filepath.Join(os.TempDir(), fmt.Sprintf("qm-serve-test-%d.sock", time.Now().UnixNano()))
	t.Cleanup(func() { os.Remove(socketPath) }) //nolint:errcheck
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()

	changes := newManualChangeSource()
	srv := &Server{
		SocketPath:    socketPath,
		Snapshotter:   NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return now }),
		ClockInterval: time.Hour,
		ChangeSource:  changes,
	}
	errc := make(chan error, 1)
	go func() { errc <- srv.Serve(ctx) }()
	waitForSocket(t, socketPath)

	conn, enc, dec := dialServe(t, socketPath)
	defer conn.Close() //nolint:errcheck
	writeRequest(t, enc, map[string]any{
		"id":     "sub",
		"method": "subscribe",
		"topics": []string{"tracker"},
	})
	assertResponseTopic(t, dec, "subscribe")
	initial := assertEventTopic(t, dec, "tracker")
	if !envelopeContains(initial, `"state":"done"`) {
		t.Fatalf("initial tracker event = %#v, want done state", initial)
	}

	now = lastEvent.Add(state.DoneToIdleGrace + time.Second)
	changes.Publish(clockChange())
	seen := readEventsUntil(t, conn, dec, time.Second, func(env Envelope, seen map[string]bool) bool {
		return env.Type == "event" && env.Topic == "tracker" && envelopeContains(env, `"state":"idle"`)
	})
	if !seen["tracker"] {
		t.Fatalf("clock events = %v, want tracker idle update", seen)
	}

	ss, err := state.LoadSessionState("qm-demo")
	if err != nil {
		t.Fatalf("load state after clock: %v", err)
	}
	if got := ss.Panes["primary"].State; got != "idle" {
		t.Fatalf("state.json primary state = %q, want idle", got)
	}

	cancel()
	if err := <-errc; err != nil {
		t.Fatalf("server returned error: %v", err)
	}
}

func TestServerRealChangeStillPushesPromptly(t *testing.T) {
	env := seedServeFixture(t)
	socketPath := filepath.Join(os.TempDir(), fmt.Sprintf("qm-serve-test-%d.sock", time.Now().UnixNano()))
	t.Cleanup(func() { os.Remove(socketPath) }) //nolint:errcheck
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()

	changes := newManualChangeSource()
	srv := &Server{
		SocketPath:    socketPath,
		Snapshotter:   NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return env.now }),
		ClockInterval: time.Hour,
		ChangeSource:  changes,
	}
	errc := make(chan error, 1)
	go func() { errc <- srv.Serve(ctx) }()
	waitForSocket(t, socketPath)

	conn, enc, dec := dialServe(t, socketPath)
	defer conn.Close() //nolint:errcheck
	writeRequest(t, enc, map[string]any{
		"id":       "sub",
		"method":   "subscribe",
		"topics":   []string{"board", "tracker", "quest"},
		"quest_id": "DEMO-1",
	})
	assertResponseTopic(t, dec, "subscribe")
	for _, want := range []string{"board", "tracker", "quest"} {
		assertEventTopic(t, dec, want)
	}

	updateSessionActivity(t, env.now)
	changes.Publish(Change{Topics: []string{topicBoard, topicTracker, topicQuest}, QuestIDs: []string{"DEMO-1"}, SessionIDs: []string{"qm-demo"}})

	seen := readEventsUntil(t, conn, dec, time.Second, func(env Envelope, seen map[string]bool) bool {
		return env.Type == "event" && env.Topic == "tracker" && envelopeContains(env, "Question: approve?")
	})
	if !seen["tracker"] {
		t.Fatalf("real change events = %v, want tracker", seen)
	}

	cancel()
	if err := <-errc; err != nil {
		t.Fatalf("server returned error: %v", err)
	}
}

func TestServerFileWatchPushesQuestChangesWithoutTracker(t *testing.T) {
	env := seedServeFixture(t)
	socketPath := filepath.Join(os.TempDir(), fmt.Sprintf("qm-serve-test-%d.sock", time.Now().UnixNano()))
	t.Cleanup(func() { os.Remove(socketPath) }) //nolint:errcheck
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()

	srv := &Server{
		SocketPath:    socketPath,
		Snapshotter:   NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return env.now }),
		ClockInterval: time.Hour,
	}
	errc := make(chan error, 1)
	go func() { errc <- srv.Serve(ctx) }()
	waitForSocket(t, socketPath)

	conn, enc, dec := dialServe(t, socketPath)
	defer conn.Close() //nolint:errcheck

	writeRequest(t, enc, map[string]any{
		"id":       "sub",
		"method":   "subscribe",
		"topics":   []string{"board", "tracker", "quest"},
		"quest_id": "DEMO-1",
	})
	assertResponseTopic(t, dec, "subscribe")
	for _, want := range []string{"board", "tracker", "quest"} {
		assertEventTopic(t, dec, want)
	}

	q, err := quest.DefaultStore().Load("DEMO-1")
	if err != nil {
		t.Fatalf("load quest for update: %v", err)
	}
	q.Title = "Serve runtime JSON updated"
	if err := quest.DefaultStore().Save(q); err != nil {
		t.Fatalf("save updated quest: %v", err)
	}

	matchedQuest := false
	seen := readEventsUntil(t, conn, dec, 2*time.Second, func(env Envelope, seen map[string]bool) bool {
		if seenQuestChange(env, "Serve runtime JSON updated") {
			matchedQuest = true
		}
		return matchedQuest && seen["board"] && seen["quest"]
	})
	if !seen["board"] || !seen["quest"] {
		t.Fatalf("quest file events = %v, want board and quest", seen)
	}
	if seen["tracker"] {
		t.Fatalf("quest file change pushed tracker too: %v", seen)
	}

	cancel()
	if err := <-errc; err != nil {
		t.Fatalf("server returned error: %v", err)
	}
}

func TestServerFileWatchPushesNewQuestCreate(t *testing.T) {
	env := seedServeFixture(t)
	socketPath := filepath.Join(os.TempDir(), fmt.Sprintf("qm-serve-test-%d.sock", time.Now().UnixNano()))
	t.Cleanup(func() { os.Remove(socketPath) }) //nolint:errcheck
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()

	srv := &Server{
		SocketPath:    socketPath,
		Snapshotter:   NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return env.now }),
		ClockInterval: time.Hour,
	}
	errc := make(chan error, 1)
	go func() { errc <- srv.Serve(ctx) }()
	waitForSocket(t, socketPath)

	conn, enc, dec := dialServe(t, socketPath)
	defer conn.Close() //nolint:errcheck

	writeRequest(t, enc, map[string]any{
		"id":       "sub",
		"method":   "subscribe",
		"topics":   []string{"board", "quest"},
		"quest_id": "DEMO-2",
	})
	assertResponseTopic(t, dec, "subscribe")
	assertEventTopic(t, dec, "board")
	assertErrorEnvelope(t, dec, "DEMO-2")

	if err := quest.DefaultStore().Save(&quest.Quest{
		ID:      "DEMO-2",
		Title:   "New quest while serving",
		Status:  quest.StatusActive,
		Summary: "Prove create events",
		Project: "questmaster",
		Body:    []quest.Block{{Type: quest.BlockText, Text: "Created after serve started"}},
	}); err != nil {
		t.Fatalf("save new quest: %v", err)
	}

	matchedQuest := false
	seen := readEventsUntil(t, conn, dec, 2*time.Second, func(env Envelope, seen map[string]bool) bool {
		if env.Type == "event" && env.Topic == "quest" && envelopeContains(env, "New quest while serving") {
			matchedQuest = true
		}
		return matchedQuest && seen["board"] && seen["quest"]
	})
	if !seen["board"] || !seen["quest"] {
		t.Fatalf("new quest create events = %v, want board and quest", seen)
	}

	cancel()
	if err := <-errc; err != nil {
		t.Fatalf("server returned error: %v", err)
	}
}

func TestServerFileWatchPushesNewSessionAndFirstStateWrite(t *testing.T) {
	env := seedServeFixture(t)
	socketPath := filepath.Join(os.TempDir(), fmt.Sprintf("qm-serve-test-%d.sock", time.Now().UnixNano()))
	t.Cleanup(func() { os.Remove(socketPath) }) //nolint:errcheck
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()

	srv := &Server{
		SocketPath:    socketPath,
		Snapshotter:   NewSnapshotter(env.store, tmux.NewClient(fakeTmuxRunner{sessions: "qm-demo\nqm-created"}), func() time.Time { return env.now }),
		ClockInterval: time.Hour,
	}
	errc := make(chan error, 1)
	go func() { errc <- srv.Serve(ctx) }()
	waitForSocket(t, socketPath)

	conn, enc, dec := dialServe(t, socketPath)
	defer conn.Close() //nolint:errcheck

	writeRequest(t, enc, map[string]any{
		"id":     "sub",
		"method": "subscribe",
		"topics": []string{"tracker"},
	})
	assertResponseTopic(t, dec, "subscribe")
	assertEventTopic(t, dec, "tracker")

	if err := os.MkdirAll(state.SessionStateDir(env.store.Root(), "qm-created"), 0o755); err != nil {
		t.Fatalf("create session state dir: %v", err)
	}
	if err := env.store.Create(state.Manifest{
		SessionID:   "qm-created",
		Title:       "Created while serving",
		Cwd:         env.worktree,
		SessionType: "standalone",
		Agents:      []state.AgentManifest{{Name: "codex", Role: "primary"}},
	}); err != nil {
		t.Fatalf("create manifest while serving: %v", err)
	}

	readEventsUntil(t, conn, dec, 2*time.Second, func(env Envelope, seen map[string]bool) bool {
		return env.Type == "event" && env.Topic == "tracker" && envelopeContains(env, "qm-created")
	})

	if err := state.SaveSessionState("qm-created", &state.SessionState{
		SessionID: "qm-created",
		Version:   state.SchemaVersion,
		Panes: map[string]state.PaneState{
			"primary": {
				Role:         "primary",
				Agent:        "codex",
				State:        "working",
				Activity:     "Bash: first watched state write",
				LastKind:     "PreToolUse",
				LastEvent:    env.now.Add(-time.Minute),
				WorkingSince: env.now.Add(-time.Minute),
			},
		},
	}); err != nil {
		t.Fatalf("save first state.json for new session: %v", err)
	}

	seen := readEventsUntil(t, conn, dec, 2*time.Second, func(env Envelope, seen map[string]bool) bool {
		return env.Type == "event" && env.Topic == "tracker" && envelopeContains(env, "Bash: first watched state write")
	})
	if !seen["tracker"] {
		t.Fatalf("new session state write events = %v, want tracker", seen)
	}

	cancel()
	if err := <-errc; err != nil {
		t.Fatalf("server returned error: %v", err)
	}
}

func TestServerResumeReadsDurableStateWrittenWhileDown(t *testing.T) {
	env := seedServeFixture(t)
	socketPath := filepath.Join(os.TempDir(), fmt.Sprintf("qm-serve-test-%d.sock", time.Now().UnixNano()))
	t.Cleanup(func() { os.Remove(socketPath) }) //nolint:errcheck

	start := func(ctx context.Context) <-chan error {
		errc := make(chan error, 1)
		srv := &Server{
			SocketPath:    socketPath,
			Snapshotter:   NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return env.now }),
			ClockInterval: time.Hour,
		}
		go func() { errc <- srv.Serve(ctx) }()
		waitForSocket(t, socketPath)
		return errc
	}

	ctx1, cancel1 := context.WithCancel(t.Context())
	errc1 := start(ctx1)
	conn1, enc1, dec1 := dialServe(t, socketPath)
	writeRequest(t, enc1, map[string]any{"id": "1", "method": "quest", "quest_id": "DEMO-1"})
	env1 := assertResponseTopic(t, dec1, "quest")
	if !envelopeContains(env1, "Serve runtime JSON") {
		t.Fatalf("initial quest response = %#v", env1)
	}
	conn1.Close() //nolint:errcheck
	cancel1()
	if err := <-errc1; err != nil {
		t.Fatalf("first server returned error: %v", err)
	}

	q, err := quest.DefaultStore().Load("DEMO-1")
	if err != nil {
		t.Fatalf("load quest for down-server update: %v", err)
	}
	q.Title = "Durable after restart"
	if err := quest.DefaultStore().Save(q); err != nil {
		t.Fatalf("save down-server quest update: %v", err)
	}

	ctx2, cancel2 := context.WithCancel(t.Context())
	errc2 := start(ctx2)
	conn2, enc2, dec2 := dialServe(t, socketPath)
	defer conn2.Close() //nolint:errcheck
	writeRequest(t, enc2, map[string]any{"id": "2", "method": "quest", "quest_id": "DEMO-1"})
	env2 := assertResponseTopic(t, dec2, "quest")
	if !envelopeContains(env2, "Durable after restart") {
		t.Fatalf("restarted quest response = %#v", env2)
	}
	cancel2()
	if err := <-errc2; err != nil {
		t.Fatalf("second server returned error: %v", err)
	}
}

func TestServerQuestMutationEndpointsMutateAndPush(t *testing.T) {
	env := seedServeFixture(t)
	socketPath := filepath.Join(os.TempDir(), fmt.Sprintf("qm-serve-test-%d.sock", time.Now().UnixNano()))
	t.Cleanup(func() { os.Remove(socketPath) }) //nolint:errcheck
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()

	srv := &Server{
		SocketPath:    socketPath,
		Snapshotter:   NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return env.now }),
		ClockInterval: time.Hour,
	}
	errc := make(chan error, 1)
	go func() { errc <- srv.Serve(ctx) }()
	waitForSocket(t, socketPath)

	conn, enc, dec := dialServe(t, socketPath)
	defer conn.Close() //nolint:errcheck

	writeRequest(t, enc, map[string]any{
		"id":       "sub",
		"method":   "subscribe",
		"topics":   []string{"board", "quest"},
		"quest_id": "DEMO-1",
	})
	assertResponseTopic(t, dec, "subscribe")
	assertEventTopic(t, dec, "board")
	assertEventTopic(t, dec, "quest")

	gate := sendMutation(t, socketPath, map[string]any{
		"id":       "gate",
		"method":   "quest.gate_toggle",
		"quest_id": "DEMO-1",
		"data":     map[string]any{"gate": "reviewed"},
	})
	if !envelopeContains(gate, `"checked":true`) {
		t.Fatalf("gate mutation response = %#v, want checked true", gate)
	}
	seenGate := readEventsUntil(t, conn, dec, 2*time.Second, func(env Envelope, seen map[string]bool) bool {
		return env.Type == "event" && env.Topic == "quest" && envelopeContains(env, `"checked":true`)
	})
	if !seenGate["quest"] {
		t.Fatalf("gate toggle events = %v, want quest", seenGate)
	}

	status := sendMutation(t, socketPath, map[string]any{
		"id":       "status",
		"method":   "quest.status",
		"quest_id": "DEMO-1",
		"data":     map[string]any{"status": "done"},
	})
	if !envelopeContains(status, `"status":"done"`) {
		t.Fatalf("status mutation response = %#v, want done", status)
	}
	seenStatus := readEventsUntil(t, conn, dec, 2*time.Second, func(env Envelope, seen map[string]bool) bool {
		return env.Type == "event" && env.Topic == "quest" && envelopeContains(env, `"status":"done"`)
	})
	if !seenStatus["quest"] {
		t.Fatalf("status events = %v, want quest", seenStatus)
	}

	comment := sendMutation(t, socketPath, map[string]any{
		"id":       "comment",
		"method":   "quest.comment_add",
		"quest_id": "DEMO-1",
		"data": map[string]any{
			"anchor": "quest",
			"body":   "Native app mutation note.",
		},
	})
	if !envelopeContains(comment, "Native app mutation note.") {
		t.Fatalf("comment mutation response = %#v, want comment body", comment)
	}
	seenComment := readEventsUntil(t, conn, dec, 2*time.Second, func(env Envelope, seen map[string]bool) bool {
		return env.Type == "event" && env.Topic == "quest" && envelopeContains(env, "Native app mutation note.")
	})
	if !seenComment["quest"] {
		t.Fatalf("comment events = %v, want quest", seenComment)
	}

	cancel()
	if err := <-errc; err != nil {
		t.Fatalf("server returned error: %v", err)
	}
}

func TestServerSessionMutationEndpointsReexecQM(t *testing.T) {
	env := seedServeFixture(t)
	socketPath := filepath.Join(os.TempDir(), fmt.Sprintf("qm-serve-test-%d.sock", time.Now().UnixNano()))
	t.Cleanup(func() { os.Remove(socketPath) }) //nolint:errcheck
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()

	runner := &recordingMutationRunner{}
	srv := &Server{
		SocketPath:     socketPath,
		Snapshotter:    NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return env.now }),
		ClockInterval:  time.Hour,
		MutationRunner: runner,
	}
	errc := make(chan error, 1)
	go func() { errc <- srv.Serve(ctx) }()
	waitForSocket(t, socketPath)

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
			name: "quest delete",
			request: map[string]any{
				"id":       "quest-delete",
				"method":   "quest.delete",
				"quest_id": "DEMO-2",
			},
			wantArgs: []string{"quest", "delete", "DEMO-2"},
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
			name: "attach",
			request: map[string]any{
				"id":     "attach",
				"method": "attach_to_quest",
				"data":   map[string]any{"session_id": "qm-worker", "quest_id": "DEMO-1"},
			},
			wantArgs: []string{"session", "attach", "qm-worker", "--quest", "DEMO-1"},
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
					"quest_id":  "DEMO-1",
					"prompt":    "work this quest",
				},
			},
			wantArgs:  []string{"spawn", "--from-app", "--cwd", "/tmp/worker", "--primary", "codex", "--quest", "DEMO-1", "--prompt-file", "-", "--", "qm-master", "worker title"},
			wantStdin: "work this quest",
		},
		{
			name: "start",
			request: map[string]any{
				"id":     "start",
				"method": "start",
				"data": map[string]any{
					"title":    "session title",
					"cwd":      "/tmp/project",
					"primary":  "codex",
					"color":    "violet",
					"quest_id": "DEMO-1",
					"prompt":   "start this quest",
					"master":   "true",
				},
			},
			wantArgs:  []string{"start", "--from-app", "--cwd", "/tmp/project", "--primary", "codex", "--color", "violet", "--quest", "DEMO-1", "--master", "--prompt-file", "-", "--", "session title"},
			wantStdin: "start this quest",
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
		if !strings.HasPrefix(method, "quest.") && !isMutationMethod("mutation."+method) {
			t.Fatalf("registered mutation method %q is not routed through mutation. prefix", method)
		}
	}
	for _, method := range []string{"mutate", "quest.unknown", "mutation.unknown", "board"} {
		if isMutationMethod(method) {
			t.Fatalf("unregistered method %q routed as mutation", method)
		}
	}
}

func TestFirstNonEmptyReturnsTrimmedValue(t *testing.T) {
	if got := firstNonEmpty("  ", " codex ", " claude "); got != "codex" {
		t.Fatalf("firstNonEmpty returned %q, want trimmed codex", got)
	}
}

func TestServerDirSuggestReturnsPickerSuggestionsAndRecents(t *testing.T) {
	env := seedServeFixture(t)
	socketPath := filepath.Join(os.TempDir(), fmt.Sprintf("qm-serve-test-%d.sock", time.Now().UnixNano()))
	t.Cleanup(func() { os.Remove(socketPath) }) //nolint:errcheck
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()

	var gotQuery string
	srv := &Server{
		SocketPath:    socketPath,
		Snapshotter:   NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return env.now }),
		ClockInterval: time.Hour,
		DirQuerier: dirsuggest.DirQuerierFunc(func(query string) ([]string, error) {
			gotQuery = query
			return []string{"/tmp/not-a-match", "/tmp/questmaster-app", "/tmp/quest-log"}, nil
		}),
	}
	errc := make(chan error, 1)
	go func() { errc <- srv.Serve(ctx) }()
	waitForSocket(t, socketPath)

	conn, enc, dec := dialServe(t, socketPath)
	defer conn.Close() //nolint:errcheck
	writeRequest(t, enc, map[string]any{
		"id":     "dir",
		"method": "dir_suggest",
		"data":   map[string]any{"query": "quest"},
	})
	envResp := assertResponseTopic(t, dec, "dir_suggest")
	if gotQuery != "quest" {
		t.Fatalf("dir query = %q, want quest", gotQuery)
	}
	data, ok := envResp.Data.(map[string]any)
	if !ok {
		t.Fatalf("dir_suggest data = %#v, want object", envResp.Data)
	}
	suggestions := stringList(data["suggestions"])
	if !reflect.DeepEqual(suggestions, []string{"/tmp/questmaster-app", "/tmp/quest-log"}) {
		t.Fatalf("suggestions = %v, want ranked quest matches", suggestions)
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

func TestServerQuestGateAndCommentMutationsSerializeConcurrentWrites(t *testing.T) {
	t.Setenv(quest.HomeEnv, t.TempDir())
	q := &quest.Quest{
		ID:      "RACE-1",
		Title:   "Race",
		Summary: "s",
		Status:  quest.StatusActive,
		Gates:   []quest.Gate{{Name: "reviewed", Type: quest.GateToggle}},
	}
	if err := quest.DefaultStore().Save(q); err != nil {
		t.Fatalf("save seed quest: %v", err)
	}

	srv := &Server{}
	const comments = 64
	const toggles = 31
	start := make(chan struct{})
	errc := make(chan error, comments+toggles)
	var wg sync.WaitGroup
	for i := 0; i < comments; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			<-start
			_, err := srv.mutateQuestCommentAdd(Request{QuestID: "RACE-1"}, mutationPayload{
				Body: fmt.Sprintf("comment %02d", i),
			})
			errc <- err
		}(i)
	}
	for i := 0; i < toggles; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			_, err := srv.mutateQuestGateToggle(Request{QuestID: "RACE-1"}, mutationPayload{
				Gate: "reviewed",
			})
			errc <- err
		}()
	}
	close(start)
	wg.Wait()
	close(errc)
	for err := range errc {
		if err != nil {
			t.Fatalf("mutation error: %v", err)
		}
	}

	got, err := quest.DefaultStore().Load("RACE-1")
	if err != nil {
		t.Fatalf("load final quest: %v", err)
	}
	if len(got.Comments) != comments {
		t.Fatalf("comments = %d, want %d", len(got.Comments), comments)
	}
	if !got.Gates[0].Checked {
		t.Fatalf("gate checked = false, want true after odd toggle count")
	}
}

func TestServerQuestCommentEditDeleteResolveMutationsUseLockedStore(t *testing.T) {
	t.Setenv(quest.HomeEnv, t.TempDir())
	now := time.Date(2026, 6, 21, 8, 0, 0, 0, time.UTC)
	q := &quest.Quest{
		ID:      "COMMENT-1",
		Title:   "Comment mutations",
		Summary: "s",
		Status:  quest.StatusActive,
		Comments: []quest.QuestComment{
			{
				ID:        "comment-1",
				Anchor:    quest.CommentAnchor{Kind: quest.CommentAnchorQuest},
				Status:    quest.CommentOpen,
				Body:      "before",
				CreatedAt: now.Format(time.RFC3339),
			},
			{
				ID:        "comment-2",
				Anchor:    quest.CommentAnchor{Kind: quest.CommentAnchorQuest},
				Status:    quest.CommentOpen,
				Body:      "delete me",
				CreatedAt: now.Add(time.Minute).Format(time.RFC3339),
			},
		},
	}
	if err := quest.DefaultStore().Save(q); err != nil {
		t.Fatalf("save seed quest: %v", err)
	}

	srv := &Server{}
	edit, err := srv.mutateQuestCommentEdit(Request{QuestID: "COMMENT-1"}, mutationPayload{
		CommentID: "comment-1",
		Body:      " updated body ",
	})
	if err != nil {
		t.Fatalf("edit mutation: %v", err)
	}
	if !valueContains(edit, "updated body") {
		t.Fatalf("edit response = %#v, want updated body", edit)
	}

	resolve, err := srv.mutateQuestCommentResolve(Request{QuestID: "COMMENT-1"}, mutationPayload{CommentID: "comment-1"})
	if err != nil {
		t.Fatalf("resolve mutation: %v", err)
	}
	if !valueContains(resolve, string(quest.CommentResolved)) {
		t.Fatalf("resolve response = %#v, want resolved", resolve)
	}

	deleteResult, err := srv.mutateQuestCommentDelete(Request{QuestID: "COMMENT-1"}, mutationPayload{CommentID: "comment-2"})
	if err != nil {
		t.Fatalf("delete mutation: %v", err)
	}
	if !valueContains(deleteResult, "comment-2") {
		t.Fatalf("delete response = %#v, want comment id", deleteResult)
	}

	got, err := quest.DefaultStore().Load("COMMENT-1")
	if err != nil {
		t.Fatalf("load final quest: %v", err)
	}
	if len(got.Comments) != 1 {
		t.Fatalf("comments = %d, want 1", len(got.Comments))
	}
	if got.Comments[0].ID != "comment-1" || got.Comments[0].Body != "updated body" || got.Comments[0].Status != quest.CommentResolved {
		t.Fatalf("remaining comment = %#v, want edited resolved comment-1", got.Comments[0])
	}
	if got.Comments[0].ResolvedAt == "" {
		t.Fatalf("resolved_at should be set")
	}

	if _, err := srv.mutateQuestCommentEdit(Request{QuestID: "COMMENT-1"}, mutationPayload{Body: "missing id"}); err == nil {
		t.Fatalf("edit mutation without comment_id succeeded")
	}
}

func TestServerSwitchMutationUsesLocalTmuxAction(t *testing.T) {
	env := seedServeFixture(t)
	socketPath := filepath.Join(os.TempDir(), fmt.Sprintf("qm-serve-test-%d.sock", time.Now().UnixNano()))
	t.Cleanup(func() { os.Remove(socketPath) }) //nolint:errcheck
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()

	runner := &recordingTmuxRunner{}
	srv := &Server{
		SocketPath:    socketPath,
		Snapshotter:   NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return env.now }),
		ClockInterval: time.Hour,
		TmuxClient:    tmux.NewClient(runner),
	}
	errc := make(chan error, 1)
	go func() { errc <- srv.Serve(ctx) }()
	waitForSocket(t, socketPath)

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
	if calls := runner.Calls(); len(calls) != 1 {
		t.Fatalf("bad switch should not call tmux, calls = %#v", calls)
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
	socketPath := filepath.Join(os.TempDir(), fmt.Sprintf("qm-serve-test-%d.sock", time.Now().UnixNano()))
	t.Cleanup(func() { os.Remove(socketPath) }) //nolint:errcheck
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()

	runner := &recordingMutationRunner{}
	srv := &Server{
		SocketPath:     socketPath,
		Snapshotter:    NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return env.now }),
		ClockInterval:  time.Hour,
		MutationRunner: runner,
	}
	errc := make(chan error, 1)
	go func() { errc <- srv.Serve(ctx) }()
	waitForSocket(t, socketPath)

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
	readEventsUntil(t, conn, dec, 2*time.Second, func(env Envelope, seen map[string]bool) bool {
		return env.Type == "event" && env.Topic == "tracker" && envelopeContains(env, `"display_color":"violet"`)
	})

	clearResp := sendMutation(t, socketPath, map[string]any{
		"id":     "session-clear",
		"method": "mutation.recolor",
		"data": map[string]any{
			"scope":      "session",
			"session_id": "qm-demo",
			"color":      "",
		},
	})
	if !envelopeContains(clearResp, `"scope":"session"`) {
		t.Fatalf("session clear response = %#v, want session response", clearResp)
	}
	manifest, err = env.store.Read("qm-demo")
	if err != nil {
		t.Fatalf("read cleared manifest: %v", err)
	}
	if manifest.Display != nil {
		t.Fatalf("session clear left display metadata: %#v", manifest.Display)
	}

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
	readEventsUntil(t, conn, dec, 2*time.Second, func(env Envelope, seen map[string]bool) bool {
		return env.Type == "event" && env.Topic == "tracker" && envelopeContains(env, `"color":"pink"`)
	})

	repoClear := sendMutation(t, socketPath, map[string]any{
		"id":     "repo-clear",
		"method": "recolor",
		"data": map[string]any{
			"scope":         "repo",
			"repo_identity": repoIdentity,
			"color":         "",
		},
	})
	if !envelopeContains(repoClear, `"scope":"repo"`) {
		t.Fatalf("repo clear response = %#v, want repo response", repoClear)
	}
	if _, ok, err := state.NewRepoColorStore(env.store.Root()).Get(repoIdentity); err != nil || ok {
		t.Fatalf("repo color after clear ok=%v err=%v, want cleared", ok, err)
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
	socketPath := filepath.Join(os.TempDir(), fmt.Sprintf("qm-serve-test-%d.sock", time.Now().UnixNano()))
	t.Cleanup(func() { os.Remove(socketPath) }) //nolint:errcheck
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()

	srv := &Server{
		SocketPath:    socketPath,
		Snapshotter:   NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return env.now }),
		ClockInterval: time.Hour,
	}
	errc := make(chan error, 1)
	go func() { errc <- srv.Serve(ctx) }()
	waitForSocket(t, socketPath)

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
	socketPath := filepath.Join(os.TempDir(), fmt.Sprintf("qm-serve-test-%d.sock", time.Now().UnixNano()))
	t.Cleanup(func() { os.Remove(socketPath) }) //nolint:errcheck
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
	errc := make(chan error, 1)
	go func() { errc <- srv.Serve(ctx) }()
	waitForSocket(t, socketPath)

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
	home := filepath.Join(t.TempDir(), "home")
	worktree := filepath.Join(t.TempDir(), "worktree")
	if err := os.MkdirAll(worktree, 0o755); err != nil {
		t.Fatalf("create worktree: %v", err)
	}
	t.Setenv(state.StateRootEnv, root)
	t.Setenv(quest.HomeEnv, home)
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
		QuestID:   "DEMO-1",
		QuestLoop: &state.QuestLoopState{
			Since:       now.Add(-3 * time.Minute),
			Iterations:  2,
			LastVerdict: "fail",
			Phase:       state.QuestLoopPhaseChecking,
		},
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

	q := &quest.Quest{
		ID:      "DEMO-1",
		Title:   "Serve runtime JSON",
		Status:  quest.StatusActive,
		Summary: "Expose derived runtime",
		Project: "questmaster",
		Gates: []quest.Gate{
			{Name: "tests", Type: quest.GateAuto, Check: "cmd:go test ./..."},
			{Name: "reviewed", Type: quest.GateToggle},
		},
		Related: []quest.RelatedLink{{ID: "plan", Type: "doc", Title: "Implementation plan", URL: "file:///tmp/plan.html"}},
		Body:    []quest.Block{{Type: quest.BlockText, Text: "Context block"}},
		Comments: []quest.QuestComment{{
			ID:        "comment-1",
			Anchor:    quest.CommentAnchor{Kind: quest.CommentAnchorQuest},
			Status:    quest.CommentOpen,
			Body:      "Native viewer needs this shape",
			CreatedAt: now.Format(time.RFC3339),
		}},
	}
	if err := quest.DefaultStore().Save(q); err != nil {
		t.Fatalf("save quest: %v", err)
	}
	if err := gate.NewSidecar(filepath.Join(home, "runtime")).Save("DEMO-1", []gate.Result{{
		Gate:   "tests",
		Status: gate.StatusFail,
		RanAt:  now.Add(-30 * time.Second),
	}}); err != nil {
		t.Fatalf("save sidecar: %v", err)
	}

	return serveFixture{
		store:      store,
		tmuxClient: tmux.NewClient(fakeTmuxRunner{sessions: "qm-demo"}),
		now:        now,
		worktree:   worktree,
	}
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

func assertErrorEnvelope(t *testing.T, dec *json.Decoder, contains string) {
	t.Helper()
	var env Envelope
	if err := dec.Decode(&env); err != nil {
		t.Fatalf("decode error envelope: %v", err)
	}
	if env.Type != "response" || env.OK == nil || *env.OK || !strings.Contains(env.Error, contains) {
		t.Fatalf("error envelope = %#v, want error containing %q", env, contains)
	}
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

func boardContainsQuestTitle(board BoardSnapshot, title string) bool {
	for _, group := range board.Groups {
		for _, row := range group.Quests {
			if row.Quest.Title == title {
				return true
			}
		}
	}
	return false
}

func seenQuestChange(env Envelope, title string) bool {
	return env.Type == "event" && env.Topic == "quest" && envelopeContains(env, title)
}

func envelopeContains(env Envelope, needle string) bool {
	raw, _ := json.Marshal(env.Data)
	return strings.Contains(string(raw), needle)
}

func valueContains(value any, needle string) bool {
	raw, _ := json.Marshal(value)
	return strings.Contains(string(raw), needle)
}
