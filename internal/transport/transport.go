//go:build linux || darwin

// Package transport provides same-session primary/companion messaging.
package transport

import (
	"context"
	"errors"
	"fmt"
	"os"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
)

const (
	// CompanionNotAvailableMessage preserves the shell transport sentinel text.
	CompanionNotAvailableMessage = "COMPANION_NOT_AVAILABLE: Master sessions have no companion pane."

	primaryPrefix   = "[PRIMARY] "
	companionPrefix = "[COMPANION] "
	codexThreadKey  = "codex_thread_id"
	codexThreadEnv  = "CODEX_THREAD_ID"
)

var ErrCompanionNotAvailable = errors.New(CompanionNotAvailableMessage)

type manifestStore interface {
	Read(partyID string) (state.Manifest, error)
	Update(partyID string, fn func(*state.Manifest)) error
}

// Service sends messages between the primary and companion panes in one session.
type Service struct {
	store  manifestStore
	client *tmux.Client
}

// Result describes a successful transport attempt.
type Result struct {
	SessionID  string
	TargetRole string
	Target     string
	Warnings   []error
}

// NewService creates a same-session transport service.
func NewService(store manifestStore, client *tmux.Client) *Service {
	return &Service{store: store, client: client}
}

// Deliver routes message to the peer pane for the current pane role.
func (s *Service) Deliver(ctx context.Context, sessionID, message string) (Result, error) {
	result := Result{SessionID: sessionID}

	manifest, err := s.store.Read(sessionID)
	if err != nil {
		return result, fmt.Errorf("read manifest for %q: %w", sessionID, err)
	}
	if manifest.SessionType == "master" {
		return result, ErrCompanionNotAvailable
	}

	current, err := s.client.CurrentPane(ctx)
	if err != nil {
		return result, fmt.Errorf("resolve current pane role: %w", err)
	}
	if current.SessionName != "" && current.SessionName != sessionID {
		return result, fmt.Errorf("current pane is in session %q, not %q", current.SessionName, sessionID)
	}

	var prefix string
	switch current.Role {
	case tmux.RolePrimary:
		result.TargetRole = tmux.RoleCompanion
		prefix = primaryPrefix
	case tmux.RoleCompanion:
		result.TargetRole = tmux.RolePrimary
		prefix = companionPrefix
		if err := s.captureCodexThreadID(ctx, sessionID); err != nil {
			result.Warnings = append(result.Warnings, fmt.Errorf("capture %s: %w", codexThreadEnv, err))
		}
	default:
		return result, fmt.Errorf("cannot route from pane role %q in %s", current.Role, sessionID)
	}

	target, err := s.client.ResolveRole(ctx, sessionID, result.TargetRole, current.WindowIndex)
	if err != nil {
		return result, fmt.Errorf("resolve %s pane in %q: %w", result.TargetRole, sessionID, err)
	}
	result.Target = target

	send := s.client.Send(ctx, target, prefix+message)
	if send.Err != nil {
		return result, fmt.Errorf("send to %s in %s: %w", result.TargetRole, sessionID, send.Err)
	}
	return result, nil
}

func (s *Service) captureCodexThreadID(ctx context.Context, sessionID string) error {
	threadID := os.Getenv(codexThreadEnv)
	if threadID == "" {
		return nil
	}

	manifest, err := s.store.Read(sessionID)
	if err != nil {
		return err
	}
	if manifest.ExtraString(codexThreadKey) != "" {
		return nil
	}

	changed := false
	if err := s.store.Update(sessionID, func(m *state.Manifest) {
		if m.ExtraString(codexThreadKey) != "" {
			return
		}
		m.SetExtra(codexThreadKey, threadID)
		changed = true
	}); err != nil {
		return err
	}
	if !changed {
		return nil
	}
	return s.client.SetEnvironment(ctx, sessionID, codexThreadEnv, threadID)
}
