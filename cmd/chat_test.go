package cmd

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/workerfeed"
)

func TestChatCommandHistoryAndRendering(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createFeedManifests(t, store, "qm-master", "qm-w1", "qm-w2")
	if err := store.Update("qm-w1", func(m *state.Manifest) { m.Title = "chat-feed-backend" }); err != nil {
		t.Fatal(err)
	}
	for i, event := range []struct {
		worker string
		kind   string
		text   string
	}{
		{"qm-w1", "message", "one"},
		{"qm-w2", "message", "other worker"},
		{"qm-w1", "action", "Bash"},
		{"qm-w1", "action", "Bash"},
	} {
		activity := ""
		if event.kind == "action" {
			activity = "Bash: go test ./..."
		}
		fields := map[string]interface{}{"chat_entries": []interface{}{map[string]interface{}{"chat_kind": event.kind, "chat_text": event.text}}}
		if err := state.AppendStateEventAt(store.Root(), event.worker, state.StateEvent{Ts: time.Unix(int64(i+1), 0), Activity: activity, Fields: fields}); err != nil {
			t.Fatal(err)
		}
	}

	t.Run("JSON worker filter and pagination", func(t *testing.T) {
		t.Parallel()
		out := runCmd(t, store, &mockRunner{}, "chat", "qm-master", "--worker", "qm-w1", "--limit", "2")
		var page workerfeed.HistoryPage
		if err := json.Unmarshal([]byte(out), &page); err != nil {
			t.Fatal(err)
		}
		if page.MasterID != "qm-master" || page.WorkerID != "qm-w1" || len(page.Entries) != 2 {
			t.Fatalf("page = %#v", page)
		}
		if page.NextBefore == "" || page.Entries[0].Text != "Bash" {
			t.Fatalf("page pagination/order = %#v", page)
		}
	})

	t.Run("expanded text includes summaries", func(t *testing.T) {
		t.Parallel()
		out := runCmd(t, store, &mockRunner{}, "chat", "qm-master", "--worker", "qm-w1", "--expand")
		if strings.Contains(out, "x2") || !strings.Contains(out, "Bash: go test ./...") {
			t.Fatalf("expanded output = %q", out)
		}
	})

	t.Run("text keeps the full worker title", func(t *testing.T) {
		t.Parallel()
		out := runCmd(t, store, &mockRunner{}, "chat", "qm-master", "--worker", "qm-w1", "--text")
		if !strings.Contains(out, "chat-feed-backend: one") || strings.Contains(out, "chat-feed-backen:") {
			t.Fatalf("text output truncated worker title: %q", out)
		}
	})
}

func TestChatTextAndBeforeKeepLateNarrationChronological(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createFeedManifests(t, store, "qm-master", "qm-w1")
	base := time.Date(2026, 10, 7, 12, 0, 0, 0, time.UTC)
	appendChatEvent := func(kind, text string, at time.Time, chatAt time.Time) {
		fields := map[string]interface{}{"chat_entries": []interface{}{map[string]interface{}{"chat_kind": kind, "chat_text": text}}}
		if !chatAt.IsZero() {
			fields["chat_entries"].([]interface{})[0].(map[string]interface{})["chat_timestamp"] = chatAt.Format(time.RFC3339Nano)
		}
		if err := state.AppendStateEventAt(store.Root(), "qm-w1", state.StateEvent{Ts: at, Fields: fields}); err != nil {
			t.Fatal(err)
		}
	}
	appendChatEvent("action", "Read", base.Add(time.Second), time.Time{})
	appendChatEvent("say", "Reading the README.", base.Add(2*time.Second), base)

	all := runCmd(t, store, &mockRunner{}, "chat", "qm-master", "--text")
	if !strings.Contains(all, "Worker qm-w1: Reading the README.\n") || !strings.HasSuffix(all, "Worker qm-w1: Cast [Read]\n") {
		t.Fatalf("chat --text output = %q", all)
	}
	first := runCmd(t, store, &mockRunner{}, "chat", "qm-master", "--limit", "1")
	var page workerfeed.HistoryPage
	if err := json.Unmarshal([]byte(first), &page); err != nil {
		t.Fatal(err)
	}
	if len(page.Entries) != 1 || page.Entries[0].Kind != "action" || page.NextBefore == "" {
		t.Fatalf("latest page = %#v", page)
	}
	older := runCmd(t, store, &mockRunner{}, "chat", "qm-master", "--before", page.NextBefore, "--text")
	if !strings.Contains(older, "Worker qm-w1: Reading the README.") || strings.Contains(older, "Cast [Read]") {
		t.Fatalf("chat --before output = %q", older)
	}
}

func TestChatBeforePagesLateEntriesByTimestamp(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createFeedManifests(t, store, "qm-master", "qm-w1")
	base := time.Date(2026, 10, 7, 12, 0, 0, 0, time.UTC)
	appendChatEvent := func(kind, text string, eventAt, chatAt time.Time) {
		entry := map[string]interface{}{"chat_kind": kind, "chat_text": text}
		if !chatAt.IsZero() {
			entry["chat_timestamp"] = chatAt.Format(time.RFC3339Nano)
		}
		if err := state.AppendStateEventAt(store.Root(), "qm-w1", state.StateEvent{
			Ts:     eventAt,
			Fields: map[string]interface{}{"chat_entries": []interface{}{entry}},
		}); err != nil {
			t.Fatal(err)
		}
	}
	appendChatEvent("action", "Read", base, time.Time{})
	appendChatEvent("action", "Edit", base.Add(4*time.Second), time.Time{})
	for i, text := range []string{"first", "second", "third"} {
		appendChatEvent("say", text, base.Add(time.Duration(5+i)*time.Second), base.Add(time.Duration(i+1)*time.Second))
	}

	var collected []workerfeed.Entry
	before := ""
	for pages := 0; pages < 8; pages++ {
		args := []string{"chat", "qm-master", "--limit", "1"}
		if before != "" {
			args = append(args, "--before", before)
		}
		out := runCmd(t, store, &mockRunner{}, args...)
		var page workerfeed.HistoryPage
		if err := json.Unmarshal([]byte(out), &page); err != nil {
			t.Fatal(err)
		}
		if len(page.Entries) != 1 {
			t.Fatalf("page before %q = %#v, want one entry", before, page.Entries)
		}
		collected = append(collected, page.Entries[0])
		if page.NextBefore == "" {
			before = ""
			break
		}
		before = page.NextBefore
	}
	if before != "" || len(collected) != 5 {
		t.Fatalf("pagination returned %d entries and next_before %q; want five entries and no cursor", len(collected), before)
	}
	want := []struct{ kind, text string }{
		{"action", "Read"}, {"say", "first"}, {"say", "second"}, {"say", "third"}, {"action", "Edit"},
	}
	for i := range want {
		got := collected[len(collected)-1-i]
		if got.Kind != want[i].kind || got.Text != want[i].text {
			t.Fatalf("chronological entry %d = %s %q, want %s %q; pages = %#v", i, got.Kind, got.Text, want[i].kind, want[i].text, collected)
		}
	}
	text := runCmd(t, store, &mockRunner{}, "chat", "qm-master", "--text")
	wantOrder := []string{
		"Worker qm-w1: Cast [Read]",
		"Worker qm-w1: first",
		"Worker qm-w1: second",
		"Worker qm-w1: third",
		"Worker qm-w1: Cast [Edit]",
	}
	last := -1
	for _, line := range wantOrder {
		at := strings.Index(text, line)
		if at <= last {
			t.Fatalf("chat --text output = %q; want line %q after offset %d", text, line, last)
		}
		last = at
	}
}

func TestChatCommandReportsPartialWorkerFailure(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createFeedManifests(t, store, "qm-master", "qm-w1", "qm-w2")
	if err := state.AppendStateEventAt(store.Root(), "qm-w1", state.StateEvent{
		Ts:     time.Unix(1, 0),
		Fields: map[string]interface{}{"chat_entries": []interface{}{map[string]interface{}{"chat_kind": "message", "chat_text": "available"}}},
	}); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(state.SessionStateLogPath(store.Root(), "qm-w2"), 0o700); err != nil {
		t.Fatal(err)
	}

	jsonOut := runCmd(t, store, &mockRunner{}, "chat", "qm-master")
	var page workerfeed.HistoryPage
	if err := json.Unmarshal([]byte(jsonOut), &page); err != nil {
		t.Fatal(err)
	}
	if len(page.Entries) != 1 || page.Errors["qm-w2"] == "" {
		t.Fatalf("partial JSON page = %#v", page)
	}

	textOut := runCmd(t, store, &mockRunner{}, "chat", "qm-master", "--text")
	if !strings.Contains(textOut, "Worker qm-w2: [Error]") {
		t.Fatalf("text output missing worker error: %q", textOut)
	}
	if _, err := runCmdErr(t, store, &mockRunner{}, "chat", "qm-master", "--worker", "qm-w2"); err == nil {
		t.Fatal("single-worker command succeeded despite unreadable log")
	}
}

func TestChatCommandDiscoversCurrentMaster(t *testing.T) {
	t.Setenv(state.SessionEnv, "")
	store := setupStore(t)
	createFeedManifests(t, store, "qm-master", "qm-w1")
	out := runCmd(t, store, displayRunner("qm-master"), "chat")
	var page workerfeed.HistoryPage
	if err := json.Unmarshal([]byte(out), &page); err != nil {
		t.Fatal(err)
	}
	if page.MasterID != "qm-master" {
		t.Fatalf("master_id = %q, want qm-master", page.MasterID)
	}
}

func createFeedManifests(t *testing.T, store *state.Store, masterID string, workers ...string) {
	t.Helper()
	manifest := state.Manifest{SessionID: masterID, SessionType: "master", Workers: workers}
	if err := store.Create(manifest); err != nil {
		t.Fatal(err)
	}
	for _, workerID := range workers {
		worker := state.Manifest{SessionID: workerID, Title: "Worker " + workerID}
		worker.SetExtra("parent_session", masterID)
		if err := store.Create(worker); err != nil {
			t.Fatal(err)
		}
	}
}
