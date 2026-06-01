package tui

import (
	"fmt"
	"os"
	"path/filepath"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/alexivison/questmaster/internal/message"
	"github.com/alexivison/questmaster/internal/session"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
)

// Launch starts the Bubble Tea TUI application.
func Launch() error {
	m := newAutoModel()
	p := tea.NewProgram(m, tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		return fmt.Errorf("tui: %w", err)
	}
	return nil
}

// LaunchAgents starts the tracker as a standalone agents roster — every
// session across all repos, fed by the same live fetcher as the questmaster
// sidebar. Unlike Launch it tolerates the absence of a "current" session, so it
// runs from any shell; inside a session it still highlights the current one.
// Used by `quests agents` and as the in-session sidebar.
func LaunchAgents() error {
	root := stateRoot()
	store, err := state.NewStore(root)
	if err != nil {
		return fmt.Errorf("cannot initialize state store at %s: %w", root, err)
	}
	client := tmux.NewExecClient()
	m := NewModel(store, client)
	m.tracker = buildTrackerModel(store, client)
	if auto := m.autoResolver; auto != nil {
		m.resolver = func() (SessionInfo, error) {
			info, rerr := auto.Resolve()
			if rerr != nil {
				// No current session (e.g. launched from a plain shell): show
				// the roster without a highlighted current rather than erroring.
				return SessionInfo{}, nil
			}
			return info, nil
		}
	}
	p := tea.NewProgram(m, tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		return fmt.Errorf("tui: %w", err)
	}
	return nil
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

// stateRoot returns the questmaster state directory from env or default.
func stateRoot() string {
	if root := state.StateRoot(); root != "" {
		return root
	}
	home, _ := os.UserHomeDir()
	if home == "" {
		return ""
	}
	return filepath.Join(home, ".questmaster-state")
}
