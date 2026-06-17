package quest

import "github.com/charmbracelet/lipgloss"

// theme is the one small palette the terminal renderer draws from. The quests
// app is its own TUI in a shell pane, so it uses truecolor close to the
// quest-ui-mockup, honouring the terminal-honest constraints (one background,
// structure from colour + weight, no panels). Golden tests strip ANSI, so
// these colours never affect asserted output — only the live display.
var theme = struct {
	id       lipgloss.Style // quest id (cyan)
	title    lipgloss.Style // quest title
	section  lipgloss.Style // OBJECTIVE / DEFINITION OF DONE / RELATED headers
	meta     lipgloss.Style // dim frontmatter line
	metaVal  lipgloss.Style // values within the meta line
	fg       lipgloss.Style // body prose
	muted    lipgloss.Style
	dim      lipgloss.Style
	faint    lipgloss.Style
	heading  lipgloss.Style // body heading
	gateAuto lipgloss.Style // auto gate glyph/type
	gateTog  lipgloss.Style // toggle gate glyph/type
	comment  lipgloss.Style // open comment marker
	flag     lipgloss.Style // quest flag (amber) used on tracker + list
	rich     lipgloss.Style // rich placeholder ("in the browser")
	statusOf func(Status) lipgloss.Style
}{
	id:       lipgloss.NewStyle().Foreground(lipgloss.Color("#4ec3d6")).Bold(true),
	title:    lipgloss.NewStyle().Foreground(lipgloss.Color("#eef3fb")).Bold(true),
	section:  lipgloss.NewStyle().Foreground(lipgloss.Color("#e6b860")),
	meta:     lipgloss.NewStyle().Foreground(lipgloss.Color("#5a6577")),
	metaVal:  lipgloss.NewStyle().Foreground(lipgloss.Color("#7e8a9e")),
	fg:       lipgloss.NewStyle().Foreground(lipgloss.Color("#c2ccdb")),
	muted:    lipgloss.NewStyle().Foreground(lipgloss.Color("#7e8a9e")),
	dim:      lipgloss.NewStyle().Foreground(lipgloss.Color("#5a6577")),
	faint:    lipgloss.NewStyle().Foreground(lipgloss.Color("#3a4354")),
	heading:  lipgloss.NewStyle().Foreground(lipgloss.Color("#dbe4f1")).Bold(true),
	gateAuto: lipgloss.NewStyle().Foreground(lipgloss.Color("#4ec3d6")),
	gateTog:  lipgloss.NewStyle().Foreground(lipgloss.Color("#e6b860")),
	comment:  lipgloss.NewStyle().Foreground(lipgloss.Color("#e6b860")),
	flag:     lipgloss.NewStyle().Foreground(lipgloss.Color("#e6b860")),
	rich:     lipgloss.NewStyle().Foreground(lipgloss.Color("#5a6577")).Italic(true),
	statusOf: func(s Status) lipgloss.Style {
		switch s {
		case StatusActive:
			return lipgloss.NewStyle().Foreground(lipgloss.Color("#82d273"))
		case StatusDone:
			return lipgloss.NewStyle().Foreground(lipgloss.Color("#5a6577"))
		default: // wip
			return lipgloss.NewStyle().Foreground(lipgloss.Color("#7e8a9e")).Italic(true)
		}
	},
}

var boardListIDStyle = theme.dim.Bold(true)

func listIDStyle(status Status) lipgloss.Style {
	switch status {
	case StatusActive:
		return theme.flag.Bold(true)
	default:
		return theme.dim.Bold(true)
	}
}

func gateTypeStyle(t GateType) lipgloss.Style {
	switch t {
	case GateAuto:
		return theme.gateAuto
	case GateToggle:
		return theme.gateTog
	default:
		return theme.dim
	}
}
