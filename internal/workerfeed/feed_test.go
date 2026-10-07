//go:build linux || darwin

package workerfeed

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/state"
)

func TestDeriveWorkerEvent(t *testing.T) {
	t.Parallel()

	for _, tc := range []struct {
		name   string
		states []string
		want   []string
	}{
		{name: "status dedupe and idle suppression", states: []string{"working", "working", "idle", "done", "done", "blocked"}, want: []string{"working", "done", "blocked"}},
		{name: "unlisted states are suppressed", states: []string{"starting", "idle", "stopped"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			cursor := Cursor{}
			var got []Entry
			for _, value := range tc.states {
				got = append(got, deriveWorkerEvent("qm-w1", "Worker", state.StateEvent{State: value}, &cursor)...)
			}
			if len(got) != len(tc.want) {
				t.Fatalf("entries = %#v, want %v", got, tc.want)
			}
			for i, text := range tc.want {
				if got[i].Kind != "status" || got[i].Text != text {
					t.Errorf("entry %d = %#v, want status %q", i, got[i], text)
				}
			}
		})
	}

	t.Run("sub-agent event is excluded", func(t *testing.T) {
		t.Parallel()
		cursor := Cursor{}
		got := deriveWorkerEvent("qm-w1", "Worker", state.StateEvent{
			State: "working",
			Fields: map[string]interface{}{
				"agent_id":  "agent-1",
				"chat_kind": "action",
				"chat_text": "Bash",
			},
		}, &cursor)
		if len(got) != 0 || cursor.LastState != "" {
			t.Fatalf("sub-agent entries/state = %#v/%q, want none/empty", got, cursor.LastState)
		}
	})

	t.Run("message cap is multibyte safe", func(t *testing.T) {
		t.Parallel()
		cursor := Cursor{}
		text := strings.Repeat("猫", maxTextChars+20)
		got := deriveWorkerEvent("qm-w1", "Worker", state.StateEvent{Fields: map[string]interface{}{
			"chat_kind": "message",
			"chat_text": text,
		}}, &cursor)
		if len(got) != 1 || got[0].Kind != "message" {
			t.Fatalf("entries = %#v, want one message", got)
		}
		if len([]rune(got[0].Text)) != maxTextChars || !strings.HasSuffix(got[0].Text, "猫") {
			t.Fatalf("message rune length/end = %d/%q", len([]rune(got[0].Text)), got[0].Text[len(got[0].Text)-3:])
		}
	})

	t.Run("message cap keeps at most three paragraphs", func(t *testing.T) {
		t.Parallel()
		cursor := Cursor{}
		got := deriveWorkerEvent("qm-w1", "Worker", state.StateEvent{Fields: map[string]interface{}{
			"chat_kind": "message",
			"chat_text": "one\n\ntwo\n\nthree\n\nfour",
		}}, &cursor)
		if len(got) != 1 || got[0].Text != "one\n\ntwo\n\nthree" {
			t.Fatalf("paragraph-capped message = %#v", got)
		}
	})

	t.Run("OpenCode assistant text waits for role confirmation and done", func(t *testing.T) {
		t.Parallel()
		cursor := Cursor{}
		part := state.StateEvent{Ts: time.Unix(1, 0), State: "working", Action: "message.part.updated", Fields: map[string]interface{}{
			"workerfeed_part_id":   "msg-1",
			"workerfeed_part_text": "finished work",
		}}
		if got := deriveWorkerEvent("qm-w1", "Worker", part, &cursor); len(got) != 1 || got[0].Kind != "status" {
			t.Fatalf("unconfirmed part entries = %#v, want only working status", got)
		}
		confirmed := state.StateEvent{Ts: time.Unix(2, 0), State: "working", Action: "message.updated", Fields: map[string]interface{}{
			"workerfeed_assistant_message_id": "msg-1",
		}}
		if got := deriveWorkerEvent("qm-w1", "Worker", confirmed, &cursor); len(got) != 0 {
			t.Fatalf("confirmed message emitted before done: %#v", got)
		}
		done := state.StateEvent{Ts: time.Unix(3, 0), State: "done", Action: "session.idle"}
		got := deriveWorkerEvent("qm-w1", "Worker", done, &cursor)
		if len(got) != 2 || got[0].Kind != "message" || got[0].Text != "finished work" || got[1].Kind != "status" {
			t.Fatalf("done entries = %#v, want final message then done status", got)
		}
	})
}

func TestReadSinceRotationAndBoundedTail(t *testing.T) {
	t.Parallel()

	t.Run("continues through the retained rotated file", func(t *testing.T) {
		t.Parallel()
		root := t.TempDir()
		createMasterAndWorkers(t, root, "qm-master", "qm-w1")
		appendEvent(t, root, "qm-w1", event("working", time.Unix(1, 0)))
		first, err := ReadSince(root, "qm-master", nil)
		if err != nil {
			t.Fatal(err)
		}
		cursor := first.Cursors["qm-w1"]
		appendEvent(t, root, "qm-w1", event("done", time.Unix(2, 0)))
		path := state.SessionStateLogPath(root, "qm-w1")
		if err := os.Rename(path, path+".1"); err != nil {
			t.Fatal(err)
		}
		appendEvent(t, root, "qm-w1", event("working", time.Unix(3, 0)))

		next, err := ReadSince(root, "qm-master", map[string]Cursor{"qm-w1": cursor})
		if err != nil {
			t.Fatal(err)
		}
		if len(next.Entries) != 2 || next.Entries[0].Text != "done" || next.Entries[1].Text != "working" {
			t.Fatalf("rotated entries = %#v, want done then working", next.Entries)
		}
		if next.Cursors["qm-w1"].FileID == cursor.FileID {
			t.Fatalf("cursor file id did not advance after rotation: %#v", next.Cursors["qm-w1"])
		}
	})

	t.Run("first load reads only the bounded tail", func(t *testing.T) {
		t.Parallel()
		root := t.TempDir()
		createMasterAndWorkers(t, root, "qm-master", "qm-w1")
		path := state.SessionStateLogPath(root, "qm-w1")
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		prefix := strings.Repeat("x", InitialTailBytes+1024)
		body := []byte(prefix + "\n")
		body = append(body, mustMarshalEvent(event("done", time.Unix(4, 0)))...)
		if err := os.WriteFile(path, body, 0o600); err != nil {
			t.Fatal(err)
		}
		got, err := ReadSince(root, "qm-master", nil)
		if err != nil {
			t.Fatal(err)
		}
		if len(got.Entries) != 1 || got.Entries[0].Text != "done" {
			t.Fatalf("entries = %#v, want only the valid tail event", got.Entries)
		}
		if got.Cursors["qm-w1"].Offset < int64(len(body)-InitialTailBytes-2) {
			t.Fatalf("cursor offset = %d, did not start near bounded tail", got.Cursors["qm-w1"].Offset)
		}
	})

	t.Run("first load includes the retained file when the current file is small", func(t *testing.T) {
		t.Parallel()
		root := t.TempDir()
		createMasterAndWorkers(t, root, "qm-master", "qm-w1")
		path := state.SessionStateLogPath(root, "qm-w1")
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path+".1", mustMarshalEvent(event("working", time.Unix(1, 0))), 0o600); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, mustMarshalEvent(event("done", time.Unix(2, 0))), 0o600); err != nil {
			t.Fatal(err)
		}
		got, err := ReadSince(root, "qm-master", nil)
		if err != nil {
			t.Fatal(err)
		}
		if len(got.Entries) != 2 || got.Entries[0].Text != "working" || got.Entries[1].Text != "done" {
			t.Fatalf("first load entries = %#v, want rotated working then current done", got.Entries)
		}
		if got.Cursors["qm-w1"].FileID == "" {
			t.Fatalf("current cursor missing after first load: %#v", got.Cursors["qm-w1"])
		}
	})
}

func TestReadHistoryFilteringLimitAndPagination(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	createMasterAndWorkers(t, root, "qm-master", "qm-w1", "qm-w2")

	for i, item := range []struct {
		worker string
		kind   string
		text   string
	}{
		{"qm-w1", "message", "one"},
		{"qm-w2", "message", "two"},
		{"qm-w1", "message", "three"},
		{"qm-w1", "message", "four"},
	} {
		appendEvent(t, root, item.worker, state.StateEvent{
			Ts: time.Unix(int64(i+1), 0),
			Fields: map[string]interface{}{
				"chat_kind": item.kind,
				"chat_text": item.text,
			},
		})
	}

	first, err := ReadHistory(root, "qm-master", "qm-w1", time.Time{}, 2)
	if err != nil {
		t.Fatal(err)
	}
	if len(first.Entries) != 2 || first.Entries[0].Text != "three" || first.Entries[1].Text != "four" {
		t.Fatalf("filtered limited page = %#v", first.Entries)
	}
	if first.NextBefore == "" {
		t.Fatal("next_before is empty for a full page")
	}

	before, err := time.Parse(time.RFC3339Nano, first.NextBefore)
	if err != nil {
		t.Fatal(err)
	}
	second, err := ReadHistory(root, "qm-master", "qm-w1", before, 2)
	if err != nil {
		t.Fatal(err)
	}
	if len(second.Entries) != 1 || second.Entries[0].Text != "one" {
		t.Fatalf("older page = %#v, want only one", second.Entries)
	}
}

func TestRenderTextCollapsesAndExpandsActions(t *testing.T) {
	t.Parallel()
	entries := []Entry{
		{Timestamp: time.Date(2026, 10, 7, 12, 0, 0, 0, time.UTC), WorkerID: "qm-w1", WorkerTitle: "Worker One", Kind: "action", Text: "Bash", Summary: "Bash: go test ./..."},
		{Timestamp: time.Date(2026, 10, 7, 12, 0, 1, 0, time.UTC), WorkerID: "qm-w1", WorkerTitle: "Worker One", Kind: "action", Text: "Bash", Summary: "Bash: go test ./..."},
		{Timestamp: time.Date(2026, 10, 7, 12, 0, 2, 0, time.UTC), WorkerID: "qm-w1", WorkerTitle: "Worker One", Kind: "action", Text: "Edit", Summary: "Edit: feed.go"},
		{Timestamp: time.Date(2026, 10, 7, 12, 0, 3, 0, time.UTC), WorkerID: "qm-w1", WorkerTitle: "Worker One", Kind: "status", Text: "done"},
	}

	collapsed := RenderText(entries, false)
	if !strings.Contains(collapsed, "Worker One: Cast [Bash] x2, [Edit]") || strings.Contains(collapsed, "go test") {
		t.Fatalf("collapsed output = %q", collapsed)
	}
	expanded := RenderText(entries, true)
	if strings.Contains(expanded, "x2") || !strings.Contains(expanded, "Bash: go test ./...") || !strings.Contains(expanded, "Edit: feed.go") {
		t.Fatalf("expanded output = %q", expanded)
	}
}

func createMasterAndWorkers(t *testing.T, root, masterID string, workers ...string) {
	t.Helper()
	store, err := state.NewStore(root)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Create(state.Manifest{SessionID: masterID, SessionType: "master", Workers: workers}); err != nil {
		t.Fatal(err)
	}
	for _, workerID := range workers {
		manifest := state.Manifest{SessionID: workerID, Title: "Worker " + workerID[len("qm-"):]}
		manifest.SetExtra("parent_session", masterID)
		if err := store.Create(manifest); err != nil {
			t.Fatal(err)
		}
	}
}

func appendEvent(t *testing.T, root, workerID string, event state.StateEvent) {
	t.Helper()
	if err := state.AppendStateEventAt(root, workerID, event); err != nil {
		t.Fatal(err)
	}
}

func event(status string, at time.Time) state.StateEvent {
	return state.StateEvent{Ts: at, State: status}
}

func mustMarshalEvent(event state.StateEvent) []byte {
	data, err := json.Marshal(event)
	if err != nil {
		panic(err)
	}
	return append(data, '\n')
}
