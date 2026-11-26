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
	return s.NotifyWithCheck(ctx, sessionID, text, nil)
}

// NotifyWithCheck uses the same readiness checks as Notify, then runs beforeSend
// immediately before submission. A check error aborts delivery.
func (s *Service) NotifyWithCheck(ctx context.Context, sessionID, text string, beforeSend func() error) (Delivery, error) {
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
	if activity == "starting" {
		now := time.Now()
		if _, err := state.MarkSessionObservedAt(s.store.Root(), sessionID, now); err != nil {
			return "", err
		}
		ss, err = state.LoadSessionStateAt(s.store.Root(), sessionID)
		if err != nil {
			return "", err
		}
		activity = sessionactivity.FromState(ss).State
		if activity == "starting" {
			lastEvent := ss.Panes["agent"].LastEvent
			if lastEvent.IsZero() || now.Sub(lastEvent) >= state.StartingToIdleGrace {
				return "", fmt.Errorf("alert recipient %s remains in starting activity state", sessionID)
			}
		}
	}
	if activity == "unknown" || activity == "stopped" {
		return "", fmt.Errorf("alert recipient %s has %s activity state", sessionID, activity)
	}
	if activity != "idle" && activity != "done" {
		return "", nil
	}
	target, err := client.ResolveRole(ctx, sessionID, agentRole, tmux.WindowWorkspace)
	if err != nil {
		return "", err
	}
	if err := s.nativeDeliver(ctx, client, m, target, text, beforeSend); err == nil {
		return DeliveryAccepted, nil
	} else if !errors.Is(err, errNativeUnavailable) {
		return "", err
	}
	busy, err := client.RecentClientActivity(ctx, sessionID, time.Now(), notificationQuietPeriod)
	if err != nil || busy {
		return "", err
	}
	if err := client.SendWithCheck(ctx, state.SendLockDirForServer(s.store.Root(), handle.SendLockNamespace()), target, text, beforeSend).Err; err != nil {
		return "", err
	}
	return DeliverySubmitted, nil
}
