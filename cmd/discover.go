package cmd

import (
	"context"
	"fmt"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
)

// discoverMasterSession resolves the current tmux session and validates it is
// a master session. Discovery order:
//  1. QUESTMASTER_SESSION env var override
//  2. Current tmux session via display-message
func discoverMasterSession(ctx context.Context, store *state.Store, client *tmux.Client) (string, error) {
	name, err := discoverSession(ctx, client)
	if err != nil {
		return "", err
	}
	m, err := store.Read(name)
	if err != nil {
		return "", fmt.Errorf("read manifest for %q: %w", name, err)
	}
	if m.SessionType != "master" {
		return "", fmt.Errorf("session %q is not a master session (type: %q)", name, m.SessionType)
	}
	return name, nil
}

// discoverSession resolves the current questmaster session. Checks
// QUESTMASTER_SESSION first, then falls back to the current tmux session name.
func discoverSession(ctx context.Context, client *tmux.Client) (string, error) {
	name := state.SessionIDFromEnv()
	if name == "" {
		var err error
		name, err = client.SessionName(ctx)
		if err != nil {
			return "", fmt.Errorf("discover session: %w", err)
		}
	}
	if !state.IsValidSessionID(name) {
		return "", fmt.Errorf("current session %q is not a questmaster session (expected qm-*)", name)
	}
	return name, nil
}
