package tui

import (
	"fmt"
	"os"
	"path/filepath"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/anthropics/ai-config/tools/party-cli/internal/state"
	"github.com/anthropics/ai-config/tools/party-cli/internal/tmux"
)

// Option configures the TUI launch.
type Option func(*launchOpts)

type launchOpts struct {
	sessionOverride string
}

// WithSession forces a specific session ID instead of auto-discovery.
func WithSession(id string) Option {
	return func(o *launchOpts) { o.sessionOverride = id }
}

// Launch starts the Bubble Tea TUI application.
// When no options are provided, it auto-discovers the session from environment.
func Launch(opts ...Option) error {
	o := launchOpts{}
	for _, apply := range opts {
		apply(&o)
	}

	var m Model
	if o.sessionOverride != "" {
		m = NewModelWithResolver(staticResolver(o.sessionOverride))
	} else {
		m = newAutoModel()
	}

	p := tea.NewProgram(m, tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		return fmt.Errorf("tui: %w", err)
	}
	return nil
}

// staticResolver returns a resolver for an explicit --session override.
// Errors are propagated so the TUI shows a clear failure state.
func staticResolver(sessionID string) SessionResolver {
	return func() (string, ViewMode, error) {
		root := stateRoot()
		store, err := state.NewStore(root)
		if err != nil {
			return "", ViewWorker, fmt.Errorf("cannot initialize state store: %w", err)
		}
		manifest, err := store.Read(sessionID)
		if err != nil {
			return "", ViewWorker, fmt.Errorf("cannot read manifest for %s: %w", sessionID, err)
		}
		if manifest.SessionType == "master" {
			return sessionID, ViewMaster, nil
		}
		return sessionID, ViewWorker, nil
	}
}

// newAutoModel builds a model using environment-derived state root.
// Propagates store init errors as resolver errors so the TUI surfaces them.
func newAutoModel() Model {
	root := stateRoot()
	store, err := state.NewStore(root)
	if err != nil {
		storeErr := fmt.Errorf("cannot initialize state store at %s: %w", root, err)
		return NewModelWithResolver(func() (string, ViewMode, error) {
			return "", ViewWorker, storeErr
		})
	}
	client := tmux.NewExecClient()
	return NewModel(store, client)
}

// stateRoot returns the party state directory from env or default.
func stateRoot() string {
	if root := os.Getenv("PARTY_STATE_ROOT"); root != "" {
		return root
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".party-state")
}
