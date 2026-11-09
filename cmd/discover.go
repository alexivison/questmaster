package cmd

import (
	"context"
	"fmt"
	"os"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmuxroute"
)

func discoverMasterSession(ctx context.Context, store *state.Store, client *tmux.Client) (string, error) {
	router, err := tmuxroute.NewProduction(store, client)
	if err != nil {
		return "", err
	}
	return discoverMasterSessionRouted(ctx, store, router)
}

func discoverMasterSessionRouted(ctx context.Context, store *state.Store, router *tmuxroute.Router) (string, error) {
	name, err := discoverSessionRouted(ctx, store, router)
	if err != nil {
		return "", err
	}
	m, err := store.Read(name)
	if err != nil {
		return "", fmt.Errorf("read manifest for %q: %w", name, err)
	}
	if m.AgentSessionType() != "master" {
		return "", fmt.Errorf("session %q is not a master session (type: %q)", name, m.AgentSessionType())
	}
	return name, nil
}

// discoverSession resolves the current managed session through recorded routes.
func discoverSession(ctx context.Context, client *tmux.Client) (string, error) {
	store := state.OpenStore(state.StateRoot())
	router, err := tmuxroute.NewProduction(store, client)
	if err != nil {
		return "", err
	}
	return discoverSessionRouted(ctx, store, router)
}

func discoverSessionRouted(ctx context.Context, store *state.Store, router *tmuxroute.Router) (string, error) {
	if name := state.SessionIDFromEnv(); name != "" {
		if !state.IsValidSessionID(name) {
			return "", fmt.Errorf("current session %q is not a questmaster session (expected qm-*)", name)
		}
		m, err := store.Read(name)
		if err != nil {
			return "", fmt.Errorf("read manifest for %q: %w", name, err)
		}
		if _, err := router.Route(m); err != nil {
			return "", err
		}
		return name, nil
	}
	if label := os.Getenv("QUESTMASTER_TMUX_SERVER"); label != "" {
		// This only registers a candidate client. SessionName checks the
		// caller's exact socket and pane, then the manifest confirms ownership.
		_, _ = router.Route(state.Manifest{TmuxServer: state.TmuxServer(label)})
	}
	handles, err := router.KnownHandles()
	if err != nil {
		return "", err
	}
	for _, handle := range handles {
		name, err := handle.Client().SessionName(ctx)
		if err != nil || !state.IsValidSessionID(name) {
			continue
		}
		m, err := store.Read(name)
		if err != nil {
			continue
		}
		recorded, err := router.Route(m)
		if err != nil || recorded.Label() != handle.Label() {
			continue
		}
		return name, nil
	}
	return "", fmt.Errorf("discover session: caller is not in a managed tmux pane")
}

func commandRouter(store *state.Store, client *tmux.Client, routes []*tmuxroute.Router) (*tmuxroute.Router, error) {
	if len(routes) > 0 && routes[0] != nil {
		return routes[0], nil
	}
	return tmuxroute.NewProduction(store, client)
}
