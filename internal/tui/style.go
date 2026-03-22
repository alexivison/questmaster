package tui

import "github.com/charmbracelet/lipgloss"

// ANSI palette colors — inherits terminal theme automatically.
// Ported from tools/party-tracker/main.go.
var (
	blue  = lipgloss.Color("4")
	green = lipgloss.Color("2")
	dim   = lipgloss.Color("8")
	red   = lipgloss.Color("1")

	titleStyle         = lipgloss.NewStyle().Foreground(blue).Bold(true)
	activeStyle        = lipgloss.NewStyle().Foreground(green)
	stoppedStyle       = lipgloss.NewStyle().Foreground(red)
	dimStyle           = lipgloss.NewStyle().Foreground(dim)
	selectedStyle      = lipgloss.NewStyle().Foreground(blue).Bold(true)
	snippetStyleWide   = lipgloss.NewStyle().Foreground(dim).PaddingLeft(6)
	snippetStyleNarrow = lipgloss.NewStyle().Foreground(dim).PaddingLeft(3)
	footerStyle        = lipgloss.NewStyle().Foreground(dim)
	headerRule         = lipgloss.NewStyle().Foreground(dim)
)

// compactThreshold is the terminal width below which compact rendering activates.
const compactThreshold = 50
