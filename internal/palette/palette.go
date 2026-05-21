package palette

import "github.com/charmbracelet/lipgloss"

const (
	Added      lipgloss.Color = "2"
	Deleted    lipgloss.Color = "1"
	HunkHeader lipgloss.Color = "6"

	Clean      lipgloss.Color = Added
	Warn       lipgloss.Color = "3"
	Error      lipgloss.Color = Deleted
	Accent     lipgloss.Color = "4"
	Muted      lipgloss.Color = "8"
	StatusBg   lipgloss.Color = "0"
	StatusFg   lipgloss.Color = "7"
	DividerFg  lipgloss.Color = Muted
	BrightText lipgloss.Color = "15"

	MasterRole lipgloss.Color = "11"
	// WorkerRole is the picker-reference worker identity color; tracker worker
	// dots and headers share it so the two UIs stay aligned.
	WorkerRole     lipgloss.Color = "5"
	StandaloneRole lipgloss.Color = Clean
	TmuxRole       lipgloss.Color = Accent
	OrphanRole     lipgloss.Color = Muted

	DividerBorder         lipgloss.Color = Muted
	PickerVerticalDivider lipgloss.Color = Muted
	SelectedBoxBorder     lipgloss.Color = Muted

	// Agent-identity colors. The activity icon adopts the per-agent hue so
	// the same Claude / Codex / Pi swatch is recognisable across every
	// tracker row regardless of session role. Truecolor hex on purpose:
	// each value matches the agent's brand palette.
	ClaudeColor lipgloss.Color = "#CC785C"
	CodexColor  lipgloss.Color = "#1A73E8"
	PiColor     lipgloss.Color = "#A371F7"
)

var SelectedRowBg = lipgloss.AdaptiveColor{
	Light: "#eaeef2",
	Dark:  "#2d333b",
}
