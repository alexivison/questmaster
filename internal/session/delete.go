package session

import (
	"context"
	"errors"
	"fmt"
	"os"

	"github.com/alexivison/questmaster/internal/state"
)

// Delete removes a session and its workers, returning the watches actually
// dropped. A master's cascade over its workers runs under the master's
// lifecycle lock, and each worker under its own as well.
func (s *Service) Delete(ctx context.Context, sessionID string) (int, error) {
	if err := validateSessionID(sessionID); err != nil {
		return 0, err
	}
	dropped := 0
	err := s.locked(ctx, []string{sessionID}, func(ctx context.Context) error {
		if m, err := s.Store.Read(sessionID); err == nil && m.AgentSessionType() == "master" {
			for _, workerID := range m.Workers {
				if err := s.locked(ctx, []string{workerID}, func(ctx context.Context) error {
					if err := s.killRecordedOrOrphan(ctx, workerID); err != nil {
						return fmt.Errorf("kill worker %s: %w", workerID, err)
					}
					count, err := s.cleanupStartedSession(workerID)
					dropped += count
					if err != nil {
						return fmt.Errorf("cleanup worker %s: %w", workerID, err)
					}
					return nil
				}); err != nil {
					return err
				}
			}
		}
		if err := s.killRecordedOrOrphan(ctx, sessionID); err != nil {
			return err
		}
		count, err := s.cleanupStartedSession(sessionID)
		dropped += count
		return err
	})
	return dropped, err
}

// killRecordedOrOrphan uses a manifest's route when present. Without one,
// inventory must be complete before Delete may kill any matching session.
func (s *Service) killRecordedOrOrphan(ctx context.Context, sessionID string) error {
	m, err := s.Store.Read(sessionID)
	if err == nil {
		handle, err := s.router().Route(m)
		if err != nil {
			return err
		}
		return handle.Client().KillSession(ctx, sessionID)
	}
	if !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("read manifest: %w", err)
	}
	router := s.router()
	router.Invalidate() // a cached absence cannot justify deleting an orphan
	inventory, err := router.CompleteInventory(ctx)
	if err != nil {
		return err
	}
	for _, row := range inventory.Rows {
		if row.ID != sessionID {
			continue
		}
		handle, err := router.Route(state.Manifest{TmuxServer: state.TmuxServer(row.Label)})
		if err != nil {
			return err
		}
		if err := handle.Client().KillSession(ctx, sessionID); err != nil {
			return err
		}
	}
	return nil
}

func (s *Service) cleanupStartedSession(sessionID string) (int, error) {
	s.deregisterFromParent(sessionID)
	s.removeRuntimeDir(sessionID)
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
