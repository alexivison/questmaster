package session

import (
	"context"
	"fmt"
)

// Delete removes a session completely: kills tmux, cleans runtime, removes manifest.
func (s *Service) Delete(ctx context.Context, sessionID string) error {
	if err := validateSessionID(sessionID); err != nil {
		return err
	}
	if err := s.Client.KillSession(ctx, sessionID); err != nil {
		return err
	}
	return s.cleanupDeletedSession(sessionID)
}

// Deregister removes a session from its parent master's worker list and cleans up.
// Returns an error if manifest deletion fails (stale manifest would linger).
// "Manifest not found" is tolerated — the desired state is already achieved.
func (s *Service) Deregister(sessionID string) error {
	return s.cleanupDeletedSession(sessionID)
}

func (s *Service) cleanupDeletedSession(sessionID string) error {
	s.deregisterFromParent(sessionID)
	removeRuntimeDir(sessionID)
	if err := s.Store.Delete(sessionID); err != nil && !isManifestNotFound(err) {
		return fmt.Errorf("delete manifest: %w", err)
	}
	return nil
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
