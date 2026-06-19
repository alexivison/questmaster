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

	"github.com/alexivison/questmaster/internal/quests/gate"
	"github.com/alexivison/questmaster/internal/quests/quest"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/workspace"
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

func TestSnapshotterItemsDeriveLooseStatus(t *testing.T) {
	env := seedServeFixture(t)
	itemStore := workspace.NewStore(env.store.Root())
	attached, err := itemStore.Create(workspace.CreateInput{
		Type:     "html",
		Title:    "Attached plan",
		Artifact: workspace.Artifact{Inline: "<h1>Attached</h1>"},
	})
	if err != nil {
		t.Fatalf("create attached item: %v", err)
	}
	loose, err := itemStore.Create(workspace.CreateInput{
		Type:     "html",
		Title:    "Loose plan",
		Artifact: workspace.Artifact{Inline: "<h1>Loose</h1>"},
	})
	if err != nil {
		t.Fatalf("create loose item: %v", err)
	}
	q, err := quest.DefaultStore().Load("DEMO-1")
	if err != nil {
		t.Fatalf("load quest: %v", err)
	}
	q.Attachments = append(q.Attachments, quest.AttachmentRef{ItemID: attached.ID, Type: attached.Type, Title: attached.Title})
	if err := quest.DefaultStore().Save(q); err != nil {
		t.Fatalf("save attached quest: %v", err)
	}

	items, err := NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return env.now }).Items(t.Context())
	if err != nil {
		t.Fatalf("Items: %v", err)
	}
	if len(items.Items) != 2 {
		t.Fatalf("items = %#v, want two", items.Items)
	}
	byID := map[string]workspace.ListedItem{}
	for _, item := range items.Items {
		byID[item.ID] = item
	}
	if byID[attached.ID].Loose || byID[attached.ID].AttachmentCount != 1 {
		t.Fatalf("attached item usage = %#v, want non-loose count 1", byID[attached.ID])
	}
	if !byID[loose.ID].Loose || byID[loose.ID].AttachmentCount != 0 {
		t.Fatalf("loose item usage = %#v, want loose count 0", byID[loose.ID])
	}
}

func TestServerItemsTopicAndActiveItemPublish(t *testing.T) {
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

	writeRequest(t, enc, map[string]any{"id": "items", "method": "items"})
	assertResponseTopic(t, dec, "items")

	writeRequest(t, enc, map[string]any{
		"id":     "sub",
		"method": "subscribe",
		"topics": []string{"items", "active_item"},
	})
	assertResponseTopic(t, dec, "subscribe")
	assertEventTopic(t, dec, "items")

	itemStore := workspace.NewStore(env.store.Root())
	created, err := itemStore.Create(workspace.CreateInput{
		Type:     "html",
		Title:    "Watched item",
		Artifact: workspace.Artifact{Inline: "<h1>Watched</h1>"},
	})
	if err != nil {
		t.Fatalf("create watched item: %v", err)
	}

	seenItems := readEventsUntil(t, conn, dec, 2*time.Second, func(env Envelope, seen map[string]bool) bool {
		return env.Type == "event" && env.Topic == "items" && envelopeContains(env, created.ID)
	})
	if !seenItems["items"] {
		t.Fatalf("item create events = %v, want items", seenItems)
	}

	if err := PublishActiveItem(t.Context(), socketPath, ActiveItem{
		Type:  "html",
		Title: "Live doc",
		Path:  "/tmp/live.html",
	}); err != nil {
		t.Fatalf("PublishActiveItem: %v", err)
	}

	seenActive := readEventsUntil(t, conn, dec, 2*time.Second, func(env Envelope, seen map[string]bool) bool {
		return env.Type == "event" && env.Topic == "active_item" && envelopeContains(env, "Live doc")
	})
	if !seenActive["active_item"] {
		t.Fatalf("active publish events = %v, want active_item", seenActive)
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
			wantArgs:  []string{"broadcast", "qm-master", "--message-file", "-"},
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
			wantArgs:  []string{"spawn", "--cwd", "/tmp/worker", "--primary", "codex", "--quest", "DEMO-1", "--prompt-file", "-", "qm-master", "worker title"},
			wantStdin: "work this quest",
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
	deadline := time.Now().Add(timeout)
	seen := map[string]bool{}
	for time.Now().Before(deadline) {
		var env Envelope
		if err := conn.SetReadDeadline(time.Now().Add(100 * time.Millisecond)); err != nil {
			t.Fatalf("set deadline: %v", err)
		}
		if err := dec.Decode(&env); err != nil {
			continue
		}
		if env.Type == "event" {
			seen[env.Topic] = true
		}
		if done(env, seen) {
			_ = conn.SetReadDeadline(time.Time{})
			return seen
		}
	}
	_ = conn.SetReadDeadline(time.Time{})
	t.Fatalf("timed out waiting for event; saw %v", seen)
	return seen
}

func seenQuestChange(env Envelope, title string) bool {
	return env.Type == "event" && env.Topic == "quest" && envelopeContains(env, title)
}

func envelopeContains(env Envelope, needle string) bool {
	raw, _ := json.Marshal(env.Data)
	return strings.Contains(string(raw), needle)
}
