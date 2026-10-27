//go:build linux || darwin

package message

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/alexivison/questmaster/internal/sessionactivity"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
)

const notificationQuietPeriod = 15 * time.Second

// Notify sends a background alert only when the recipient is live and between turns.
// A false result means it was held for a later tick.
func (s *Service) Notify(ctx context.Context, sessionID, text string) (bool, error) {
	if !state.IsValidSessionID(sessionID) {
		return false, fmt.Errorf("invalid session id %q", sessionID)
	}
	m, err := s.store.Read(sessionID)
	if err != nil {
		return false, err
	}
	if err := rejectPlainSession(m, sessionID); err != nil {
		return false, err
	}
	alive, err := s.client.HasSession(ctx, sessionID)
	if err != nil || !alive {
		return false, err
	}
	ss, err := state.LoadSessionStateAt(s.store.Root(), sessionID)
	if err != nil {
		return false, err
	}
	activity := sessionactivity.FromState(ss).State
	if activity != "idle" && activity != "done" {
		return false, nil
	}
	target, err := s.client.ResolveRole(ctx, sessionID, agentRole, tmux.WindowWorkspace)
	if err != nil {
		return false, err
	}
	if err := s.nativeDeliver(ctx, sessionID, m, target, text); err == nil {
		return true, nil
	} else if !errors.Is(err, errNativeUnavailable) {
		return false, err
	}
	busy, err := s.client.RecentClientActivity(ctx, sessionID, time.Now(), notificationQuietPeriod)
	if err != nil || busy {
		return false, err
	}
	result := s.client.Send(ctx, target, text)
	return result.Delivered, result.Err
}
