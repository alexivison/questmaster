package session

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/anthropics/ai-config/tools/party-cli/internal/state"
)

// Stop kills a session and cleans up. If target is empty, stops all party sessions.
func (s *Service) Stop(ctx context.Context, target string) ([]string, error) {
	if target != "" {
		if !state.IsValidPartyID(target) {
			return nil, fmt.Errorf("invalid session name %q (must start with party-)", target)
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
	if !state.IsValidPartyID(sessionID) {
		return fmt.Errorf("invalid session name %q (must start with party-)", sessionID)
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

// isManifestNotFound returns true if the error indicates the manifest
// doesn't exist. This is expected during cleanup (hook or another process
// already removed it) and should not be treated as a failure.
func isManifestNotFound(err error) bool {
	return errors.Is(err, state.ErrManifestNotFound)
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
