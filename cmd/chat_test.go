package cmd

import (
	"encoding/json"
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
		fields := map[string]interface{}{"chat_kind": event.kind, "chat_text": event.text}
		if event.kind == "action" {
			fields["chat_summary"] = "Bash: go test ./..."
		}
		if err := state.AppendStateEventAt(store.Root(), event.worker, state.StateEvent{Ts: time.Unix(int64(i+1), 0), Fields: fields}); err != nil {
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
