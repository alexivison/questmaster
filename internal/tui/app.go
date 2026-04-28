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

// Launch starts the Bubble Tea TUI application.
func Launch() error {
	m := newAutoModel()
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

// stateRoot returns the party state directory from env or default.
func stateRoot() string {
	if root := os.Getenv("PARTY_STATE_ROOT"); root != "" {
		return root
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".party-state")
}
