//go:build linux || darwin

package serve

import (
	"encoding/json"
	"testing"
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
