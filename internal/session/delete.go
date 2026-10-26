package session

import (
	"context"
	"fmt"
	"os"

	"github.com/alexivison/questmaster/internal/state"
)

// Delete removes a session and its workers, returning the watches actually dropped.
func (s *Service) Delete(ctx context.Context, sessionID string) (int, error) {
	if err := validateSessionID(sessionID); err != nil {
		return 0, err
	}
	dropped := 0
	if m, err := s.Store.Read(sessionID); err == nil && m.AgentSessionType() == "master" {
		for _, workerID := range m.Workers {
			if err := s.Client.KillSession(ctx, workerID); err != nil {
				return dropped, fmt.Errorf("kill worker %s: %w", workerID, err)
			}
			count, err := s.cleanupStartedSession(workerID)
			dropped += count
			if err != nil {
				return dropped, fmt.Errorf("cleanup worker %s: %w", workerID, err)
			}
		}
	}
	if err := s.Client.KillSession(ctx, sessionID); err != nil {
		return dropped, err
	}
	count, err := s.cleanupStartedSession(sessionID)
	return dropped + count, err
}

func (s *Service) cleanupStartedSession(sessionID string) (int, error) {
	s.deregisterFromParent(sessionID)
	removeRuntimeDir(sessionID)
	removeSessionStateDir(sessionID)
	if err := s.Store.Delete(sessionID); err != nil && !isManifestNotFound(err) {
		return 0, fmt.Errorf("delete manifest: %w", err)
	}
	dropped, err := state.DropPullRequestWatches(s.Store.Root(), func(id string) bool { return id == sessionID }, false)
	if err != nil {
		return 0, fmt.Errorf("drop PR watches: %w", err)
	}
	return dropped, nil
}

func removeSessionStateDir(sessionID string) {
	root := state.StateRoot()
	if root == "" {
		return
	}
	_ = os.RemoveAll(state.SessionStateDir(root, sessionID))
}

// deregisterFromParent removes a session from its parent master's worker list.
func (s *Service) deregisterFromParent(sessionID string) {
	m, err := s.Store.Read(sessionID)
	if err != nil {
		return
	}
	parent := m.ExtraString("parent_session")
	if parent != "" {
		_ = s.Store.RemoveWorker(parent, sessionID)
	}
}
