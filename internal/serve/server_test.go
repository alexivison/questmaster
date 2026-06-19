//go:build linux || darwin

package serve

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/quests/gate"
	"github.com/alexivison/questmaster/internal/quests/quest"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
)

type fakeTmuxRunner struct {
	sessions string
}

func (r fakeTmuxRunner) Run(context.Context, ...string) (string, error) {
	return r.sessions, nil
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

func TestServerSocketReadsAndPushesUpdates(t *testing.T) {
	env := seedServeFixture(t)
	socketPath := filepath.Join(os.TempDir(), fmt.Sprintf("qm-serve-test-%d.sock", time.Now().UnixNano()))
	t.Cleanup(func() { os.Remove(socketPath) }) //nolint:errcheck
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()

	srv := &Server{
		SocketPath:  socketPath,
		Snapshotter: NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return env.now }),
		Interval:    25 * time.Millisecond,
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

	q, err := quest.DefaultStore().Load("DEMO-1")
	if err != nil {
		t.Fatalf("load quest for update: %v", err)
	}
	q.Title = "Serve runtime JSON updated"
	if err := quest.DefaultStore().Save(q); err != nil {
		t.Fatalf("save updated quest: %v", err)
	}

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		var env Envelope
		if err := conn.SetReadDeadline(time.Now().Add(250 * time.Millisecond)); err != nil {
			t.Fatalf("set deadline: %v", err)
		}
		if err := dec.Decode(&env); err != nil {
			continue
		}
		raw, _ := json.Marshal(env.Data)
		if env.Type == "event" && env.Topic == "board" && strings.Contains(string(raw), "Serve runtime JSON updated") {
			cancel()
			if err := <-errc; err != nil {
				t.Fatalf("server returned error: %v", err)
			}
			return
		}
	}
	t.Fatal("timed out waiting for pushed board update")
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
			{Name: "reviewed", Type: quest.GateToggle, Checked: true},
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

func assertResponseTopic(t *testing.T, dec *json.Decoder, topic string) {
	t.Helper()
	var env Envelope
	if err := dec.Decode(&env); err != nil {
		t.Fatalf("decode response %s: %v", topic, err)
	}
	if env.Type != "response" || env.Topic != topic || env.OK == nil || !*env.OK {
		t.Fatalf("response = %#v, want ok %s response", env, topic)
	}
}

func assertEventTopic(t *testing.T, dec *json.Decoder, topic string) {
	t.Helper()
	var env Envelope
	if err := dec.Decode(&env); err != nil {
		t.Fatalf("decode event %s: %v", topic, err)
	}
	if env.Type != "event" || env.Topic != topic {
		t.Fatalf("event = %#v, want %s event", env, topic)
	}
}
