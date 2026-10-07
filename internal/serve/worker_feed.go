//go:build linux || darwin

package serve

import (
	"bytes"
	"encoding/json"
	"fmt"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/workerfeed"
)

type workerFeedPayload struct {
	MasterID string                       `json:"master_id"`
	Cursors  map[string]workerfeed.Cursor `json:"cursors"`
}

func (s *Server) workerFeed(req Request) (any, error) {
	payload, err := decodeWorkerFeedPayload(req.Data)
	if err != nil {
		return nil, err
	}
	if _, err := requiredValue("master_id", payload.MasterID); err != nil {
		return nil, err
	}
	root := state.StateRoot()
	if s.Snapshotter != nil {
		root = s.Snapshotter.StateRoot()
	}
	return workerfeed.ReadSince(root, payload.MasterID, payload.Cursors)
}

func decodeWorkerFeedPayload(raw json.RawMessage) (workerFeedPayload, error) {
	if len(bytes.TrimSpace(raw)) == 0 {
		return workerFeedPayload{}, fmt.Errorf("worker_feed data is required")
	}
	var payload workerFeedPayload
	if err := json.Unmarshal(raw, &payload); err != nil {
		return workerFeedPayload{}, fmt.Errorf("decode worker_feed data: %w", err)
	}
	return payload, nil
}
