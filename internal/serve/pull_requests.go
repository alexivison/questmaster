//go:build linux || darwin

package serve

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"

	"github.com/alexivison/questmaster/internal/state"
)

type pullRequestsPayload struct {
	SessionID string `json:"session_id"`
}

func (s *Server) pullRequests(req Request) (any, error) {
	var payload pullRequestsPayload
	if err := json.Unmarshal(req.Data, &payload); err != nil {
		return nil, fmt.Errorf("decode pull_requests data: %w", err)
	}
	if _, err := requiredValue("session_id", payload.SessionID); err != nil {
		return nil, err
	}
	if s.Snapshotter == nil {
		return nil, fmt.Errorf("snapshotter is required")
	}
	store := s.Snapshotter.store
	if _, err := store.Read(payload.SessionID); err != nil {
		return nil, fmt.Errorf("session %s has no live manifest: %w", payload.SessionID, err)
	}
	prs, err := state.LivePullRequests(store, nil)
	if err != nil {
		return nil, err
	}
	return scopedPullRequests(store, payload.SessionID, prs), nil
}

func scopedPullRequests(store *state.Store, sessionID string, prs []state.PullRequest) []state.PullRequest {
	if len(prs) == 0 {
		return nil
	}
	scope := map[string]bool{sessionID: true}
	if manifest, err := store.Read(sessionID); err == nil && manifest.AgentSessionType() == "master" {
		for _, id := range manifest.Workers {
			scope[id] = true
		}
	}
	return filterPullRequests(prs, scope)
}

func filterPullRequests(prs []state.PullRequest, scope map[string]bool) []state.PullRequest {
	if len(prs) == 0 {
		return nil
	}
	result := make([]state.PullRequest, 0)
	for _, pr := range prs {
		watchers := make([]state.PullRequestWatcher, 0)
		for _, watcher := range pr.Watchers {
			if scope[watcher.SessionID] {
				watchers = append(watchers, watcher)
			}
		}
		if len(watchers) > 0 {
			pr.Watchers = watchers
			result = append(result, pr)
		}
	}
	return result
}

func pullRequestsRevision(prs []state.PullRequest) string {
	if len(prs) == 0 {
		return ""
	}
	data, _ := json.Marshal(prs)
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:8])
}
