package cmd

import (
	"context"
	"fmt"
	"strings"

	"github.com/anthropics/ai-config/tools/party-cli/internal/state"
	"github.com/anthropics/ai-config/tools/party-cli/internal/tmux"
)

// discoverMasterSession resolves the current tmux session and validates it is
// a master session. This replaces the shell-level discover_session +
// party_is_master pattern from party-lib.sh.
func discoverMasterSession(ctx context.Context, store *state.Store, client *tmux.Client) (string, error) {
	name, err := client.SessionName(ctx)
	if err != nil {
		return "", fmt.Errorf("discover session: %w", err)
	}
	if !strings.HasPrefix(name, "party-") {
		return "", fmt.Errorf("current session %q is not a party session", name)
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

// discoverSession resolves the current tmux session and validates it is a
// party session. Returns the session name.
func discoverSession(ctx context.Context, client *tmux.Client) (string, error) {
	name, err := client.SessionName(ctx)
	if err != nil {
		return "", fmt.Errorf("discover session: %w", err)
	}
	if !strings.HasPrefix(name, "party-") {
		return "", fmt.Errorf("current session %q is not a party session", name)
	}
	return name, nil
}
