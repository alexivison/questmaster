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

func TestCapText(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name string
		in   string
		want string
	}{
		{name: "three paragraphs", in: "one\n\ntwo\n\nthree\n\nfour", want: "one\n\ntwo\n\nthree"},
		{name: "multibyte ceiling", in: strings.Repeat("猫", maxTextChars+20), want: strings.Repeat("猫", maxTextChars)},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			got := CapText(tc.in)
			if got != tc.want {
				t.Fatalf("CapText length/end = %d/%q", len([]rune(got)), got[len(got)-3:])
			}
		})
	}
}

func TestDeriveWorkerEventIsStateless(t *testing.T) {
	t.Parallel()
	event := state.StateEvent{Ts: time.Unix(1, 0), Activity: "Bash: safe summary", Fields: map[string]interface{}{
		"chat_entries": []interface{}{
			map[string]interface{}{"chat_kind": "action", "chat_text": "Bash"},
			map[string]interface{}{"chat_kind": "status", "chat_text": "working"},
		},
	}}
	got := deriveWorkerEvent(worker{id: "qm-w1", title: "Worker"}, "1:2", 64, event)
	if len(got) != 2 || got[0].Kind != "action" || got[0].Summary != "Bash: safe summary" || got[1].Text != "working" {
		t.Fatalf("derived entries = %#v", got)
	}
}

func TestReadSinceRotationAndBoundedTail(t *testing.T) {
	t.Parallel()

	t.Run("continues through the retained rotated file", func(t *testing.T) {
		t.Parallel()
		root := t.TempDir()
		createMasterAndWorkers(t, root, "qm-master", "qm-w1")
		appendEvent(t, root, "qm-w1", chatEvent("status", "working", time.Unix(1, 0)))
		first, err := ReadSince(root, "qm-master", nil)
		if err != nil {
			t.Fatal(err)
		}
		cursor := first.Cursors["qm-w1"]
		appendEvent(t, root, "qm-w1", chatEvent("status", "done", time.Unix(2, 0)))
		path := state.SessionStateLogPath(root, "qm-w1")
		if err := os.Rename(path, path+".1"); err != nil {
			t.Fatal(err)
		}
		appendEvent(t, root, "qm-w1", chatEvent("status", "working", time.Unix(3, 0)))

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
		body = append(body, mustMarshalEvent(chatEvent("status", "done", time.Unix(4, 0)))...)
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
		if err := os.WriteFile(path+".1", mustMarshalEvent(chatEvent("status", "working", time.Unix(1, 0))), 0o600); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, mustMarshalEvent(chatEvent("status", "done", time.Unix(2, 0))), 0o600); err != nil {
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
	t.Run("stale cursor falls back to the bounded retained and current tails", func(t *testing.T) {
		t.Parallel()
		root := t.TempDir()
		createMasterAndWorkers(t, root, "qm-master", "qm-w1")
		appendEvent(t, root, "qm-w1", chatEvent("message", "retained", time.Unix(1, 0)))
		path := state.SessionStateLogPath(root, "qm-w1")
		if err := os.Rename(path, path+".1"); err != nil {
			t.Fatal(err)
		}
		appendEvent(t, root, "qm-w1", chatEvent("message", "current", time.Unix(2, 0)))

		got, err := ReadSince(root, "qm-master", map[string]Cursor{"qm-w1": {Offset: 0, FileID: "stale-inode"}})
		if err != nil {
			t.Fatal(err)
		}
		if len(got.Entries) != 2 || got.Entries[0].Text != "retained" || got.Entries[1].Text != "current" {
			t.Fatalf("stale-cursor entries = %#v, want retained then current", got.Entries)
		}
	})
}

func TestReadSinceSkipsOversizedLineAndContinues(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	createMasterAndWorkers(t, root, "qm-master", "qm-w1")
	appendEvent(t, root, "qm-w1", chatEvent("message", "before", time.Unix(1, 0)))
	first, err := ReadSince(root, "qm-master", nil)
	if err != nil {
		t.Fatal(err)
	}
	appendEvent(t, root, "qm-w1", state.StateEvent{Ts: time.Unix(2, 0), Fields: map[string]interface{}{
		"chat_entries": []interface{}{map[string]interface{}{"chat_kind": "message", "chat_text": strings.Repeat("x", maxIncrementalRead+64*1024)}},
	}})
	appendEvent(t, root, "qm-w1", chatEvent("message", "after", time.Unix(3, 0)))

	second, err := ReadSince(root, "qm-master", first.Cursors)
	if err != nil {
		t.Fatal(err)
	}
	if second.Cursors["qm-w1"].Offset <= first.Cursors["qm-w1"].Offset || !second.HasMore["qm-w1"] {
		t.Fatalf("oversized line stalled cursor: before=%#v after=%#v has_more=%v", first.Cursors["qm-w1"], second.Cursors["qm-w1"], second.HasMore["qm-w1"])
	}
	third, err := ReadSince(root, "qm-master", second.Cursors)
	if err != nil {
		t.Fatal(err)
	}
	if len(third.Entries) != 1 || third.Entries[0].Text != "after" {
		t.Fatalf("entries after oversized line = %#v", third.Entries)
	}
}

func TestReadSinceSkipsMultiMegabyteLineInBoundedPulls(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	createMasterAndWorkers(t, root, "qm-master", "qm-w1")
	appendEvent(t, root, "qm-w1", chatEvent("message", "before", time.Unix(1, 0)))
	first, err := ReadSince(root, "qm-master", nil)
	if err != nil {
		t.Fatal(err)
	}
	appendEvent(t, root, "qm-w1", state.StateEvent{Ts: time.Unix(2, 0), Fields: map[string]interface{}{
		"chat_entries": []interface{}{map[string]interface{}{"chat_kind": "message", "chat_text": strings.Repeat("x", 3*1024*1024)}},
	}})
	appendEvent(t, root, "qm-w1", chatEvent("message", "after", time.Unix(3, 0)))

	cursors := first.Cursors
	var entries []Entry
	for pull := 0; pull < 20; pull++ {
		page, err := ReadSince(root, "qm-master", cursors)
		if err != nil {
			t.Fatal(err)
		}
		previous := cursors["qm-w1"].Offset
		next := page.Cursors["qm-w1"]
		if advanced := next.Offset - previous; advanced > maxIncrementalRead {
			t.Fatalf("pull %d advanced %d bytes, want at most %d", pull, advanced, maxIncrementalRead)
		}
		entries = append(entries, page.Entries...)
		if !page.HasMore["qm-w1"] {
			break
		}
		cursors = page.Cursors
	}
	if len(entries) != 1 || entries[0].Text != "after" {
		t.Fatalf("entries after oversized line = %#v, want only the valid trailing entry", entries)
	}
}

func TestReadSinceTailLineBoundaryAndOffsetBeyondEOF(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	createMasterAndWorkers(t, root, "qm-master", "qm-w1")
	path := state.SessionStateLogPath(root, "qm-w1")
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	first := mustMarshalEvent(chatEvent("message", "first", time.Unix(1, 0)))
	second := mustMarshalEvent(chatEvent("message", "second", time.Unix(2, 0)))
	if err := os.WriteFile(path, append(first, second...), 0o600); err != nil {
		t.Fatal(err)
	}
	file, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	info, _ := file.Stat()
	tail, _, _, err := readTail(file, worker{id: "qm-w1", title: "Worker"}, fileIdentity(info), int64(len(second)), Cursor{})
	file.Close()
	if err != nil || len(tail) != 1 || tail[0].Text != "second" {
		t.Fatalf("line-start tail = %#v, err %v", tail, err)
	}

	initial, err := ReadSince(root, "qm-master", nil)
	if err != nil || len(initial.Entries) != 2 {
		t.Fatalf("initial feed = %#v, err %v", initial, err)
	}
	cursor := initial.Cursors["qm-w1"]
	cursor.Offset += 100
	next, err := ReadSince(root, "qm-master", map[string]Cursor{"qm-w1": cursor})
	if err != nil || len(next.Entries) != 0 || next.Cursors["qm-w1"].Offset != int64(len(first)+len(second)) {
		t.Fatalf("past-EOF read = %#v, err %v", next, err)
	}
}

func TestReadSinceHasMoreAndUnreadableWorker(t *testing.T) {
	t.Parallel()
	t.Run("has more after bounded incremental read", func(t *testing.T) {
		t.Parallel()
		root := t.TempDir()
		createMasterAndWorkers(t, root, "qm-master", "qm-w1")
		path := state.SessionStateLogPath(root, "qm-w1")
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		initialEvent := mustMarshalEvent(chatEvent("message", "initial", time.Unix(1, 0)))
		if err := os.WriteFile(path, initialEvent, 0o600); err != nil {
			t.Fatal(err)
		}
		initial, err := ReadSince(root, "qm-master", nil)
		if err != nil {
			t.Fatal(err)
		}
		var backlog []byte
		for i := 0; i < 4000; i++ {
			backlog = append(backlog, mustMarshalEvent(chatEvent("action", "Bash", time.Unix(int64(i+2), 0)))...)
		}
		f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o600)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := f.Write(backlog); err != nil {
			t.Fatal(err)
		}
		f.Close()
		next, err := ReadSince(root, "qm-master", initial.Cursors)
		if err != nil {
			t.Fatal(err)
		}
		if !next.HasMore["qm-w1"] {
			t.Fatalf("has_more = %#v, want true", next.HasMore)
		}
	})
	t.Run("unreadable log preserves cursor", func(t *testing.T) {
		t.Parallel()
		root := t.TempDir()
		createMasterAndWorkers(t, root, "qm-master", "qm-w1")
		if err := os.MkdirAll(state.SessionStateLogPath(root, "qm-w1"), 0o700); err != nil {
			t.Fatal(err)
		}
		old := Cursor{Offset: 12, FileID: "unchanged"}
		got, err := ReadSince(root, "qm-master", map[string]Cursor{"qm-w1": old})
		if err != nil {
			t.Fatal(err)
		}
		if got.Cursors["qm-w1"] != old {
			t.Fatalf("cursor = %#v, want preserved %#v", got.Cursors["qm-w1"], old)
		}
		if got.Errors["qm-w1"] == "" {
			t.Fatalf("worker error = %#v, want unreadable-log indication", got.Errors)
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
		appendEvent(t, root, item.worker, chatEvent(item.kind, item.text, time.Unix(int64(i+1), 0)))
	}

	first, err := ReadHistory(root, "qm-master", "qm-w1", "", 2)
	if err != nil {
		t.Fatal(err)
	}
	if len(first.Entries) != 2 || first.Entries[0].Text != "three" || first.Entries[1].Text != "four" {
		t.Fatalf("filtered limited page = %#v", first.Entries)
	}
	if first.NextBefore == "" {
		t.Fatal("next_before is empty for a full page")
	}

	second, err := ReadHistory(root, "qm-master", "qm-w1", first.NextBefore, 2)
	if err != nil {
		t.Fatal(err)
	}
	if len(second.Entries) != 1 || second.Entries[0].Text != "one" {
		t.Fatalf("older page = %#v, want only one", second.Entries)
	}
}

func TestReadHistoryReportsUnreadableWorker(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	createMasterAndWorkers(t, root, "qm-master", "qm-w1", "qm-w2")
	appendEvent(t, root, "qm-w1", chatEvent("message", "available", time.Unix(2, 0)))
	if err := os.MkdirAll(state.SessionStateLogPath(root, "qm-w2"), 0o700); err != nil {
		t.Fatal(err)
	}

	if _, err := ReadHistory(root, "qm-master", "qm-w2", "", 10); err == nil {
		t.Fatal("single-worker read succeeded despite unreadable log")
	}
	page, err := ReadHistory(root, "qm-master", "", "", 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(page.Entries) != 1 || page.Entries[0].Text != "available" || page.Errors["qm-w2"] == "" {
		t.Fatalf("partial history = %#v, want available entry and worker error", page)
	}
}

func TestHasCompleteLineAfterBoundsLookahead(t *testing.T) {
	t.Parallel()
	path := filepath.Join(t.TempDir(), "state.jsonl")
	data := append([]byte(strings.Repeat("x", maxIncrementalRead)), '\n')
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	file, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	if hasCompleteLineAfter(file, 0, int64(len(data))) {
		t.Fatal("lookahead found a newline beyond the incremental read budget")
	}
}

func TestReadHistorySameTimestampBoundaryAndLongLine(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	createMasterAndWorkers(t, root, "qm-master", "qm-w1")
	at := time.Unix(42, 0)
	appendEvent(t, root, "qm-w1", state.StateEvent{Ts: at, Fields: map[string]interface{}{
		"chat_entries": []interface{}{
			map[string]interface{}{"chat_kind": "message", "chat_text": "same timestamp message"},
			map[string]interface{}{"chat_kind": "status", "chat_text": "done"},
		},
	}})
	appendEvent(t, root, "qm-w1", chatEvent("message", strings.Repeat("x", 70*1024), time.Unix(41, 0)))

	first, err := ReadHistory(root, "qm-master", "qm-w1", "", 1)
	if err != nil || len(first.Entries) != 1 || first.Entries[0].Text != "done" || first.NextBefore == "" {
		t.Fatalf("first page = %#v, err %v", first, err)
	}
	second, err := ReadHistory(root, "qm-master", "qm-w1", first.NextBefore, 1)
	if err != nil || len(second.Entries) != 1 || second.Entries[0].Text != "same timestamp message" {
		t.Fatalf("same-timestamp older page = %#v, err %v", second, err)
	}
	third, err := ReadHistory(root, "qm-master", "qm-w1", second.NextBefore, 1)
	if err != nil || len(third.Entries) != 1 || len(third.Entries[0].Text) != 70*1024 {
		t.Fatalf("long-line older page = len %d, err %v", len(third.Entries[0].Text), err)
	}
}

func TestRenderTextCollapsesAndExpandsActions(t *testing.T) {
	t.Parallel()
	at := time.Date(2026, 10, 7, 12, 0, 0, 0, time.UTC)
	entries := []Entry{
		{Timestamp: at, WorkerID: "qm-w1", WorkerTitle: "Worker One", Kind: "action", Text: "Bash", Summary: "Bash: go test ./..."},
		{Timestamp: at.Add(time.Second), WorkerID: "qm-w1", WorkerTitle: "Worker One", Kind: "action", Text: "Bash", Summary: "Bash: go test ./..."},
		{Timestamp: at.Add(2 * time.Second), WorkerID: "qm-w1", WorkerTitle: "Worker One", Kind: "action", Text: "Edit", Summary: "Edit: feed.go"},
		{Timestamp: at.Add(3 * time.Second), WorkerID: "qm-w1", WorkerTitle: "Worker One", Kind: "action", Text: "Edit", Summary: "Edit: feed.go"},
		{Timestamp: at.Add(4 * time.Second), WorkerID: "qm-w1", WorkerTitle: "Worker One", Kind: "action", Text: "Edit", Summary: "Edit: feed.go"},
		{Timestamp: at.Add(5 * time.Second), WorkerID: "qm-w1", WorkerTitle: "Worker One", Kind: "action", Text: "Edit", Summary: "Edit: feed.go"},
		{Timestamp: at.Add(6 * time.Second), WorkerID: "qm-w1", WorkerTitle: "Worker One", Kind: "action", Text: "Read", Summary: "Read: feed.go"},
		{Timestamp: at.Add(7 * time.Second), WorkerID: "qm-w1", WorkerTitle: "Worker One", Kind: "status", Text: "done"},
		{Timestamp: at.Add(8 * time.Second), WorkerID: "qm-w1", WorkerTitle: "Worker One", Kind: "report", Text: "Finished implementation"},
		{Timestamp: at.Add(9 * time.Second), WorkerID: "qm-w1", WorkerTitle: "Worker One", Kind: "message", Text: "Final message"},
		{Timestamp: at.Add(10 * time.Second), WorkerID: "qm-w1", WorkerTitle: "Worker One", Kind: "say", Text: "Progress update"},
	}

	collapsed := RenderText(entries, false)
	for _, want := range []string{
		"Worker One: Cast [Bash](x2) [Edit](x4) [Read]",
		"Worker One: Received status [Done]",
		"Worker One: [Report] Finished implementation",
		"Worker One: Final message",
		"Worker One: Progress update",
	} {
		if !strings.Contains(collapsed, want) {
			t.Errorf("collapsed output missing %q: %q", want, collapsed)
		}
	}
	if strings.Contains(collapsed, "go test") || strings.Contains(collapsed, "Received status:") {
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

func chatEvent(kind, text string, at time.Time) state.StateEvent {
	return state.StateEvent{Ts: at, Activity: "Safe action summary", Fields: map[string]interface{}{
		"chat_entries": []interface{}{map[string]interface{}{"chat_kind": kind, "chat_text": text}},
	}}
}

func mustMarshalEvent(event state.StateEvent) []byte {
	data, err := json.Marshal(event)
	if err != nil {
		panic(err)
	}
	return append(data, '\n')
}
