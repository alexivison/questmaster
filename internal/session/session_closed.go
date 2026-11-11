package session

import (
	"context"
	"errors"
	"fmt"
	"os"
	"time"

	"github.com/alexivison/questmaster/internal/state"
)

// SessionClosed cleans a named-server session after tmux has closed it. Worker
// membership survives closing so Continue can revive it and its log stays visible.
// The lifecycle lock fences a delayed hook from a later Continue incarnation.
func (s *Service) SessionClosed(ctx context.Context, server, sessionID string) error {
	if err := validateSessionID(sessionID); err != nil {
		return err
	}
	if server == "default" || server == "" {
		return fmt.Errorf("session-closed requires a named tmux server")
	}
	handle, err := s.router().Route(state.Manifest{TmuxServer: state.TmuxServer(server)})
	if err != nil {
		return err
	}
	lockCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	return s.Store.WithLifecycleLockContext(lockCtx, sessionID, func() error {
		m, err := s.Store.Read(sessionID)
		if errors.Is(err, state.ErrManifestNotFound) || errors.Is(err, os.ErrNotExist) {
			return nil
		}
		if err != nil {
			return err
		}
		if string(m.TmuxServer) != server {
			return nil
		}
		alive, err := handle.Client().HasSession(lockCtx, sessionID)
		if err != nil {
			return err
		}
		if alive {
			return nil
		}
		if _, err := s.persistPiResumeFromActivity(sessionID); err != nil {
			return err
		}
		s.removeRuntimeDir(sessionID)
		// Manifest writes invalidate the daemon's liveness view; closing no
		// longer rewrites the parent, so signal through this session instead.
		return s.Store.Update(sessionID, func(*state.Manifest) {})
	})
}
