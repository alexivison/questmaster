package tui

import (
	"fmt"
	"os"
	"path/filepath"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/anthropics/ai-config/tools/party-cli/internal/message"
	"github.com/anthropics/ai-config/tools/party-cli/internal/session"
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
		m = newAutoModelWithOverride(o.sessionOverride)
	} else {
		m = newAutoModel()
	}

	p := tea.NewProgram(m, tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		return fmt.Errorf("tui: %w", err)
	}
	return nil
}

// newAutoModelWithOverride builds a model for an explicit --session override.
// Uses the same manifest-reading logic as the auto-resolver but pins the session ID.
func newAutoModelWithOverride(sessionID string) Model {
	root := stateRoot()
	store, err := state.NewStore(root)
	if err != nil {
		storeErr := fmt.Errorf("cannot initialize state store at %s: %w", root, err)
		return NewModelWithResolver(func() (string, ViewMode, error) {
			return "", ViewWorker, storeErr
		})
	}
	client := tmux.NewExecClient()
	resolver := func() (string, ViewMode, error) {
		m, err := store.Read(sessionID)
		if err != nil {
			return "", ViewWorker, fmt.Errorf("cannot read manifest for %s: %w", sessionID, err)
		}
		if m.SessionType == "master" {
			return sessionID, ViewMaster, nil
		}
		return sessionID, ViewWorker, nil
	}
	model := NewModelWithResolver(resolver)
	model.trackerFactory = buildTrackerFactory(store, client)
	return model
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
	m := NewModel(store, client)
	m.trackerFactory = buildTrackerFactory(store, client)
	return m
}

// buildTrackerFactory creates a TrackerFactory from shared services.
func buildTrackerFactory(store *state.Store, client *tmux.Client) TrackerFactory {
	repoRoot := os.Getenv("PARTY_REPO_ROOT")
	sessionSvc := session.NewService(store, client, repoRoot)
	messageSvc := message.NewService(store, client)
	actions := NewLiveTrackerActions(sessionSvc, messageSvc, client, store)
	fetcher := NewLiveWorkerFetcher(messageSvc, client)
	return func(masterID string) TrackerModel {
		return NewTrackerModel(masterID, fetcher, actions)
	}
}

// stateRoot returns the party state directory from env or default.
func stateRoot() string {
	if root := os.Getenv("PARTY_STATE_ROOT"); root != "" {
		return root
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".party-state")
}
