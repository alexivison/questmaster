package session

import (
	"context"
	"fmt"
	"strings"
)

// Stop kills a session and cleans up. If target is empty, stops all party sessions.
func (s *Service) Stop(ctx context.Context, target string) ([]string, error) {
	if target != "" {
		if err := validateSessionID(target); err != nil {
			return nil, err
		}
		if err := s.stopOne(ctx, target); err != nil {
			return nil, err
		}
		return []string{target}, nil
	}

	// Stop all party sessions
	sessions, err := s.Client.ListSessions(ctx)
	if err != nil {
		return nil, fmt.Errorf("list sessions: %w", err)
	}

	var stopped []string
	for _, name := range sessions {
		if !strings.HasPrefix(name, "party-") {
			continue
		}
		if err := s.stopOne(ctx, name); err != nil {
			return stopped, fmt.Errorf("stop %s: %w", name, err)
		}
		stopped = append(stopped, name)
	}
	return stopped, nil
}

func (s *Service) stopOne(ctx context.Context, sessionID string) error {
	if err := s.Client.KillSession(ctx, sessionID); err != nil {
		return err
	}
	s.deregisterFromParent(sessionID)
	removeRuntimeDir(sessionID)
	if err := s.Store.Delete(sessionID); err != nil && !isManifestNotFound(err) {
		return fmt.Errorf("delete manifest: %w", err)
	}
	return nil
}

// Delete removes a session completely: kills tmux, cleans runtime, removes manifest.
func (s *Service) Delete(ctx context.Context, sessionID string) error {
	if err := validateSessionID(sessionID); err != nil {
		return err
	}
	if err := s.Client.KillSession(ctx, sessionID); err != nil {
		return err
	}
	s.deregisterFromParent(sessionID)
	removeRuntimeDir(sessionID)
	if err := s.Store.Delete(sessionID); err != nil && !isManifestNotFound(err) {
		return fmt.Errorf("delete manifest: %w", err)
	}
	return nil
}

// Deregister removes a session from its parent master's worker list and cleans up.
// Returns an error if manifest deletion fails (stale manifest would linger).
// "Manifest not found" is tolerated — the desired state is already achieved.
func (s *Service) Deregister(sessionID string) error {
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
