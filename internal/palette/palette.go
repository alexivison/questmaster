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
	WorkerRole     lipgloss.Color = Warn
	StandaloneRole lipgloss.Color = Clean
	TmuxRole       lipgloss.Color = Accent
	OrphanRole     lipgloss.Color = Muted

	DividerBorder         lipgloss.Color = Muted
	PickerVerticalDivider lipgloss.Color = Muted
	SelectedBoxBorder     lipgloss.Color = Muted
	ActivityDim           lipgloss.Color = Muted
)

var SelectedRowBg = lipgloss.AdaptiveColor{
	Light: "#eaeef2",
	Dark:  "#2d333b",
}
