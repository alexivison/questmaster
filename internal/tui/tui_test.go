package tui

import (
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

func TestPlaceholderModel_View(t *testing.T) {
	t.Parallel()

	m := placeholderModel{}
	view := m.View()

	if !strings.Contains(view, "party-cli") {
		t.Fatalf("expected view to contain 'party-cli', got: %s", view)
	}
}

func TestPlaceholderModel_QuitOnQ(t *testing.T) {
	t.Parallel()

	m := placeholderModel{}
	_, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'q'}})

	if cmd == nil {
		t.Fatal("expected quit command on 'q' key")
	}
}

func TestPlaceholderModel_IgnoresOtherKeys(t *testing.T) {
	t.Parallel()

	m := placeholderModel{}
	_, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'x'}})

	if cmd != nil {
		t.Fatal("expected no command on unbound key")
	}
}
