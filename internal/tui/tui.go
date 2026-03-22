package tui

import (
	"fmt"

	tea "github.com/charmbracelet/bubbletea"
)

// Launch starts the Bubble Tea TUI application.
// Placeholder model; real rendering is added in Task 7.
func Launch() error {
	p := tea.NewProgram(placeholderModel{}, tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		return fmt.Errorf("tui: %w", err)
	}
	return nil
}

type placeholderModel struct{}

func (m placeholderModel) Init() tea.Cmd { return nil }

func (m placeholderModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	if msg, ok := msg.(tea.KeyMsg); ok {
		switch msg.String() {
		case "q", "ctrl+c":
			return m, tea.Quit
		}
	}
	return m, nil
}

func (m placeholderModel) View() string {
	return "party-cli — TUI mode (placeholder)\n\nPress q to quit.\n"
}
