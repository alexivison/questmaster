//go:build linux || darwin

package serve

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/workerfeed"
)

func TestDecodeWorkerFeedPayloadVisibleWorkers(t *testing.T) {
	t.Parallel()

	var omitted workerFeedPayload
	if err := json.Unmarshal([]byte(`{"master_id":"qm-master"}`), &omitted); err != nil {
		t.Fatal(err)
	}
	if omitted.VisibleWorkerIDs != nil {
		t.Fatalf("omitted visible_worker_ids = %#v, want nil for the legacy all-visible default", omitted.VisibleWorkerIDs)
	}

	var explicit workerFeedPayload
	if err := json.Unmarshal([]byte(`{"master_id":"qm-master","visible_worker_ids":[]}`), &explicit); err != nil {
		t.Fatal(err)
	}
	if explicit.VisibleWorkerIDs == nil || len(explicit.VisibleWorkerIDs) != 0 {
		t.Fatalf("explicit empty visible_worker_ids = %#v, want an empty list for all-hidden workers", explicit.VisibleWorkerIDs)
	}

	var listed workerFeedPayload
	if err := json.Unmarshal([]byte(`{"master_id":"qm-master","visible_worker_ids":["qm-worker"]}`), &listed); err != nil {
		t.Fatal(err)
	}
	if len(listed.VisibleWorkerIDs) != 1 || listed.VisibleWorkerIDs[0] != "qm-worker" {
		t.Fatalf("visible_worker_ids = %#v, want qm-worker", listed.VisibleWorkerIDs)
	}
}

func TestWorkerFeedKeepsOmittedVisibilityRequestRaw(t *testing.T) {
	store := state.OpenStore(t.TempDir())
	t.Setenv("QUESTMASTER_STATE_ROOT", store.Root())
	master := state.Manifest{SessionID: "qm-master", Agents: []state.AgentManifest{{Name: "claude", Role: "agent"}}, Workers: []string{"qm-worker"}}
	if err := store.Create(master); err != nil {
		t.Fatal(err)
	}
	worker := state.Manifest{SessionID: "qm-worker", Title: "Worker"}
	worker.SetExtra("parent_session", "qm-master")
	if err := store.Create(worker); err != nil {
		t.Fatal(err)
	}
	event := state.StateEvent{
		Ts: time.Unix(1, 0),
		Fields: map[string]interface{}{
			"chat_entries": []interface{}{map[string]interface{}{"chat_kind": "status", "chat_text": "Checkpoint saved"}},
		},
	}
	if err := state.AppendStateEventAt(store.Root(), worker.SessionID, event); err != nil {
		t.Fatal(err)
	}
	server := &Server{Snapshotter: &Snapshotter{store: store}}

	raw, err := server.workerFeed(Request{Data: json.RawMessage(`{"master_id":"qm-master"}`)})
	if err != nil {
		t.Fatal(err)
	}
	legacyFeed := raw.(workerfeed.Response)
	if len(legacyFeed.Entries) != 1 || legacyFeed.Entries[0].Text != "Checkpoint saved" {
		t.Fatalf("omitted visibility feed = %#v, want the raw closed-worker status", legacyFeed.Entries)
	}

	native, err := server.workerFeed(Request{Data: json.RawMessage(`{"master_id":"qm-master","visible_worker_ids":[]}`)})
	if err != nil {
		t.Fatal(err)
	}
	nativeFeed := native.(workerfeed.Response)
	if len(nativeFeed.Entries) != 0 {
		t.Fatalf("explicit empty visibility feed = %#v, want no entries the Worker Log cannot display", nativeFeed.Entries)
	}
}
