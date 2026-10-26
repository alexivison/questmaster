package session

import (
	"context"
	"fmt"
	"os"

	"github.com/alexivison/questmaster/internal/state"
)

// Delete removes a session completely: kills tmux, cleans runtime, removes manifest.
func (s *Service) Delete(ctx context.Context, sessionID string) error {
	_, err := s.DeleteWithWatchCount(ctx, sessionID)
	return err
}

func (s *Service) DeleteWithWatchCount(ctx context.Context, sessionID string) (int, error) {
	if err := validateSessionID(sessionID); err != nil {
		return 0, err
	}
	ids := map[string]bool{sessionID: true}
	if m, err := s.Store.Read(sessionID); err == nil && m.AgentSessionType() == "master" {
		for _, workerID := range m.Workers {
			ids[workerID] = true
		}
	}
	dropped, err := state.DropPullRequestWatches(s.Store.Root(), func(id string) bool { return ids[id] }, true)
	if err != nil {
		return 0, err
	}
	if err := s.DeleteWorkers(ctx, sessionID); err != nil {
		return 0, err
	}
	if err := s.Client.KillSession(ctx, sessionID); err != nil {
		return 0, err
	}
	if err := s.cleanupStartedSession(sessionID); err != nil {
		return 0, err
	}
	return dropped, nil
}

// DeleteWorkers removes every worker recorded on a master manifest.
// Missing or non-master manifests are no-ops so Delete keeps its historical
// behavior for stale and corrupt manifest state.
func (s *Service) DeleteWorkers(ctx context.Context, masterID string) error {
	if err := validateSessionID(masterID); err != nil {
		return err
	}
	m, err := s.Store.Read(masterID)
	if err != nil || m.AgentSessionType() != "master" {
		return nil
	}
	for _, workerID := range m.Workers {
		if err := s.Client.KillSession(ctx, workerID); err != nil {
			return fmt.Errorf("kill worker %s: %w", workerID, err)
		}
		if err := s.cleanupStartedSession(workerID); err != nil {
			return fmt.Errorf("cleanup worker %s: %w", workerID, err)
		}
	}
	return nil
}

func (s *Service) cleanupStartedSession(sessionID string) error {
	s.deregisterFromParent(sessionID)
	removeRuntimeDir(sessionID)
	removeSessionStateDir(sessionID)
	if err := s.Store.Delete(sessionID); err != nil && !isManifestNotFound(err) {
		return fmt.Errorf("delete manifest: %w", err)
	}
	if _, err := state.DropPullRequestWatches(s.Store.Root(), func(id string) bool { return id == sessionID }, false); err != nil {
		return fmt.Errorf("drop PR watches: %w", err)
	}
	return nil
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
