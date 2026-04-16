package tui

import (
	"fmt"
	"os"
	"path/filepath"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/anthropics/ai-party/tools/party-cli/internal/message"
	"github.com/anthropics/ai-party/tools/party-cli/internal/session"
	"github.com/anthropics/ai-party/tools/party-cli/internal/state"
	"github.com/anthropics/ai-party/tools/party-cli/internal/tmux"
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

// staticResolver returns a resolver for an explicit --session override.
func staticResolver(sessionID string) SessionResolver {
	return func() (SessionInfo, error) {
		root := stateRoot()
		store, err := state.NewStore(root)
		if err != nil {
			return SessionInfo{}, fmt.Errorf("cannot initialize state store: %w", err)
		}
		manifest, err := store.Read(sessionID)
		if err != nil {
			return SessionInfo{}, fmt.Errorf("cannot read manifest for %s: %w", sessionID, err)
		}
		return SessionInfo{
			ID:          sessionID,
			Title:       manifest.Title,
			Cwd:         manifest.Cwd,
			SessionType: sessionTypeForManifest(manifest),
			Manifest:    manifest,
			Registry:    registryForManifest(manifest),
		}, nil
	}
}

// newAutoModelWithOverride builds a model for an explicit --session override.
func newAutoModelWithOverride(sessionID string) Model {
	root := stateRoot()
	store, err := state.NewStore(root)
	if err != nil {
		storeErr := fmt.Errorf("cannot initialize state store at %s: %w", root, err)
		return NewModelWithResolver(func() (SessionInfo, error) {
			return SessionInfo{}, storeErr
		})
	}
	client := tmux.NewExecClient()
	m := NewModelWithResolver(staticResolver(sessionID))
	m.tracker = buildTrackerModel(store, client)
	return m
}

// newAutoModel builds a model using environment-derived state root.
func newAutoModel() Model {
	root := stateRoot()
	store, err := state.NewStore(root)
	if err != nil {
		storeErr := fmt.Errorf("cannot initialize state store at %s: %w", root, err)
		return NewModelWithResolver(func() (SessionInfo, error) {
			return SessionInfo{}, storeErr
		})
	}
	client := tmux.NewExecClient()
	m := NewModel(store, client)
	m.tracker = buildTrackerModel(store, client)
	return m
}

func buildTrackerModel(store *state.Store, client *tmux.Client) TrackerModel {
	repoRoot := os.Getenv("PARTY_REPO_ROOT")
	sessionSvc := session.NewService(store, client, repoRoot)
	messageSvc := message.NewService(store, client)
	actions := NewLiveTrackerActions(sessionSvc, messageSvc, client, store)
	fetcher := NewLiveSessionFetcher(client, store)
	return NewTrackerModel(SessionInfo{}, fetcher, actions)
}

// stateRoot returns the party state directory from env or default.
func stateRoot() string {
	if root := os.Getenv("PARTY_STATE_ROOT"); root != "" {
		return root
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".party-state")
}
