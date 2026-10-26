//go:build linux || darwin

package serve

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"time"

	"github.com/alexivison/questmaster/internal/prstatus"
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
	statuses, err := state.LoadPullRequestStatuses(store.Root())
	if err != nil {
		return nil, err
	}
	state.AttachPullRequestStatuses(prs, statuses)
	return scopedPullRequests(store, payload.SessionID, prs), nil
}

func (s *Server) refreshPullRequests(ctx context.Context, req Request) (any, error) {
	if s.PRRefresh == nil {
		return nil, fmt.Errorf("PR polling is unavailable on this daemon")
	}
	var payload struct {
		SessionID string   `json:"session_id"`
		Keys      []string `json:"keys"`
		Wait      *bool    `json:"wait"`
	}
	if err := json.Unmarshal(req.Data, &payload); err != nil {
		return nil, fmt.Errorf("decode pr.refresh data: %w", err)
	}
	if s.Snapshotter == nil {
		return nil, fmt.Errorf("snapshotter is required")
	}
	store := s.Snapshotter.store
	var prs []state.PullRequest
	var err error
	if payload.SessionID != "" {
		var scoped any
		scoped, err = s.pullRequests(Request{Data: req.Data})
		if err != nil {
			return nil, err
		}
		prs = scoped.([]state.PullRequest)
	} else {
		prs, err = state.LoadPullRequests(store.Root())
		if err != nil {
			return nil, err
		}
	}
	if prs == nil {
		prs = []state.PullRequest{}
	}
	allowed := map[string]bool{}
	for _, pr := range prs {
		if len(pr.Watchers) > 0 {
			allowed[pr.Key] = true
		}
	}
	if len(payload.Keys) > 0 {
		for _, key := range payload.Keys {
			if !allowed[key] {
				return nil, fmt.Errorf("PR %s is not visible to session %s", key, payload.SessionID)
			}
		}
	} else if payload.SessionID != "" {
		for key := range allowed {
			payload.Keys = append(payload.Keys, key)
		}
	}
	ctx, cancel := context.WithTimeout(ctx, 28*time.Second)
	defer cancel()
	wait := payload.Wait == nil || *payload.Wait
	hosts, err := s.PRRefresh(ctx, payload.Keys, wait)
	if err != nil {
		return nil, err
	}
	statuses, err := state.LoadPullRequestStatuses(store.Root())
	if err != nil {
		return nil, err
	}
	state.AttachPullRequestStatuses(prs, statuses)
	return struct {
		PullRequests []state.PullRequest            `json:"pull_requests"`
		Hosts        map[string]prstatus.HostResult `json:"hosts"`
	}{prs, hosts}, nil
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
