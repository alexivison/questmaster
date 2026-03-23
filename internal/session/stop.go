package session

import (
	"context"
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
	s.deregisterFromParent(sessionID)
	if err := s.Client.KillSession(ctx, sessionID); err != nil {
		return err
	}
	removeRuntimeDir(sessionID)
	_ = s.Store.Delete(sessionID)
	return nil
}

// Delete removes a session completely: kills tmux, cleans runtime, removes manifest.
func (s *Service) Delete(ctx context.Context, sessionID string) error {
	if !state.IsValidPartyID(sessionID) {
		return fmt.Errorf("invalid session name %q (must start with party-)", sessionID)
	}
	s.deregisterFromParent(sessionID)
	if err := s.Client.KillSession(ctx, sessionID); err != nil {
		return err
	}
	removeRuntimeDir(sessionID)
	_ = s.Store.Delete(sessionID)
	return nil
}

// Deregister removes a session from its parent master's worker list and cleans up.
func (s *Service) Deregister(sessionID string) {
	s.deregisterFromParent(sessionID)
	removeRuntimeDir(sessionID)
	_ = s.Store.Delete(sessionID)
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
