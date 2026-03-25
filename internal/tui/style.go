package tui

import "github.com/charmbracelet/lipgloss"

// Semantic color tokens — mirrors scry's vocabulary (~/Code/scry/internal/ui/theme/theme.go).
// All use standard ANSI codes so the terminal theme decides actual RGB.
var (
	// Diff semantics.
	Added      = lipgloss.Color("2") // green
	Deleted    = lipgloss.Color("1") // red
	HunkHeader = lipgloss.Color("6") // cyan

	// Status semantics.
	Clean = Added               // green — same hue as diff additions
	Dirty = lipgloss.Color("3") // yellow
	Error = lipgloss.Color("1") // red

	// Chrome.
	Accent     = lipgloss.Color("4")   // blue — active pane border
	Muted      = lipgloss.Color("8")   // dim / bright-black
	StatusBg   = lipgloss.Color("235") // dark gray
	StatusFg   = lipgloss.Color("252") // light gray
	DividerFg  = lipgloss.Color("240") // medium gray
	BrightText = lipgloss.Color("15")  // white

	// party-cli-specific exception: gold for master identity text only.
	gold = lipgloss.Color("#ffd700")
)

// Pane and title styles.
var (
	paneTitleStyle       = lipgloss.NewStyle().Foreground(Accent).Bold(true)
	masterTitleStyle     = lipgloss.NewStyle().Foreground(gold).Bold(true)
	inactiveBorderStyle  = lipgloss.NewStyle().Foreground(Muted)
	activeBorderStyle    = lipgloss.NewStyle().Foreground(Accent)
	scrollIndicatorStyle = lipgloss.NewStyle().Foreground(BrightText)
)

// Sidebar semantic tiers — shared source of truth for worker label/value/help.
var (
	sidebarLabelStyle = lipgloss.NewStyle().Foreground(StatusFg)
	sidebarValueStyle = lipgloss.NewStyle().Foreground(Muted)
	sidebarHelpStyle  = lipgloss.NewStyle().Foreground(Muted).Faint(true)
)

// Text styles with semantic meaning.
var (
	activeTextStyle = lipgloss.NewStyle().Foreground(Clean)
	warnTextStyle   = lipgloss.NewStyle().Foreground(Dirty)
	errorTextStyle  = lipgloss.NewStyle().Foreground(Error)
	dimTextStyle    = lipgloss.NewStyle().Foreground(Muted).Faint(true)
	noteTextStyle   = lipgloss.NewStyle().Foreground(Muted).Italic(true)
)

// Tracker styles.
var (
	inactiveWorkerTitleStyle = lipgloss.NewStyle().Foreground(StatusFg)
	selectedWorkerTitleStyle = lipgloss.NewStyle().Foreground(Accent).Bold(true)
)

// Status bar and key badge styles.
var (
	statusBarStyle      = lipgloss.NewStyle().Background(StatusBg).Foreground(StatusFg)
	statusBarErrorStyle = lipgloss.NewStyle().Background(Error).Foreground(BrightText)
	keyBadgeStyle       = lipgloss.NewStyle().Background(StatusBg).Foreground(BrightText).Padding(0, 1)
	keyLabelStyle       = lipgloss.NewStyle().Foreground(Muted)
	segmentSepStyle     = lipgloss.NewStyle().Foreground(DividerFg)
	spinnerStyle        = lipgloss.NewStyle().Foreground(Accent)
)

// Snippet styles — Muted + Faint, below inactive titles in the hierarchy.
var (
	snippetStyleWide   = lipgloss.NewStyle().Foreground(Muted).Faint(true).PaddingLeft(3)
	snippetStyleNarrow = lipgloss.NewStyle().Foreground(Muted).Faint(true).PaddingLeft(2)
)

// Legacy aliases — keep existing code compiling until Tasks 2/3 migrate callers.
var (
	titleStyle  = paneTitleStyle
	activeStyle = activeTextStyle
	warnStyle   = warnTextStyle
	errorStyle  = errorTextStyle
	dimStyle    = sidebarValueStyle
	footerStyle = sidebarValueStyle
	headerRule  = sidebarValueStyle
)

// Width and height thresholds.
const (
	compactThreshold       = 50
	compactHeightThreshold = 14
)
