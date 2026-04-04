package cmd

import (
	"context"
	"fmt"
	"os"
	"strings"

	"github.com/anthropics/ai-party/tools/party-cli/internal/state"
	"github.com/anthropics/ai-party/tools/party-cli/internal/tmux"
)

// discoverMasterSession resolves the current tmux session and validates it is
// a master session. Preserves the old shell discovery order:
//  1. PARTY_SESSION env var override (testing / non-tmux scripts)
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

// discoverSession resolves the current party session. Checks PARTY_SESSION
// env var first (for testing and non-tmux contexts), then falls back to the
// current tmux session name.
func discoverSession(ctx context.Context, client *tmux.Client) (string, error) {
	name := os.Getenv("PARTY_SESSION")
	if name == "" {
		var err error
		name, err = client.SessionName(ctx)
		if err != nil {
			return "", fmt.Errorf("discover session: %w", err)
		}
	}
	if !strings.HasPrefix(name, "party-") {
		return "", fmt.Errorf("current session %q is not a party session", name)
	}
	return name, nil
}
