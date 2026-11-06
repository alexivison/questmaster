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
// An empty Delivery means the alert was held for a later tick.
func (s *Service) Notify(ctx context.Context, sessionID, text string) (Delivery, error) {
	if !state.IsValidSessionID(sessionID) {
		return "", fmt.Errorf("invalid session id %q", sessionID)
	}
	m, handle, err := s.recipient(sessionID)
	if err != nil {
		return "", err
	}
	if err := rejectPlainSession(m, sessionID); err != nil {
		return "", err
	}
	client := handle.Client()
	alive, err := client.HasSession(ctx, sessionID)
	if err != nil || !alive {
		return "", err
	}
	ss, err := state.LoadSessionStateAt(s.store.Root(), sessionID)
	if err != nil {
		return "", err
	}
	activity := sessionactivity.FromState(ss).State
	if activity != "idle" && activity != "done" {
		return "", nil
	}
	target, err := client.ResolveRole(ctx, sessionID, agentRole, tmux.WindowWorkspace)
	if err != nil {
		return "", err
	}
	if err := s.nativeDeliver(ctx, client, m, target, text); err == nil {
		return DeliveryAccepted, nil
	} else if !errors.Is(err, errNativeUnavailable) {
		return "", err
	}
	busy, err := client.RecentClientActivity(ctx, sessionID, time.Now(), notificationQuietPeriod)
	if err != nil || busy {
		return "", err
	}
	if err := client.Send(ctx, state.SendLockDirForServer(s.store.Root(), handle.SendLockNamespace()), target, text).Err; err != nil {
		return "", err
	}
	return DeliverySubmitted, nil
}
