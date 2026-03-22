package tui

import "github.com/charmbracelet/lipgloss"

// ANSI palette colors — inherits terminal theme automatically.
// Ported from tools/party-tracker/main.go.
var (
	blue = lipgloss.Color("4")
	dim  = lipgloss.Color("8")

	titleStyle = lipgloss.NewStyle().Foreground(blue).Bold(true)
	dimStyle   = lipgloss.NewStyle().Foreground(dim)
	footerStyle = lipgloss.NewStyle().Foreground(dim)
	headerRule  = lipgloss.NewStyle().Foreground(dim)
)

// compactThreshold is the terminal width below which compact rendering activates.
const compactThreshold = 50
