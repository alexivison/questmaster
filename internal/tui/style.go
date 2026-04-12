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

	// Divider color — visually matches tmux pane borders.
	DividerBorder = lipgloss.Color("#2e3440")

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

// Sidebar semantic tiers — inherit terminal foreground, use Bold/Faint for hierarchy.
var (
	sidebarLabelStyle = lipgloss.NewStyle().Bold(true)
	sidebarValueStyle = lipgloss.NewStyle().Faint(true)
	sidebarHelpStyle  = lipgloss.NewStyle().Faint(true)
)

// Text styles with semantic meaning.
// Status colors (green/yellow/red) are kept for semantic meaning.
// Dim/note styles inherit terminal foreground with Faint/Italic attributes.
var (
	activeTextStyle = lipgloss.NewStyle().Foreground(Clean)
	warnTextStyle   = lipgloss.NewStyle().Foreground(Dirty)
	errorTextStyle  = lipgloss.NewStyle().Foreground(Error)
	dimTextStyle    = lipgloss.NewStyle().Faint(true)
	noteTextStyle   = lipgloss.NewStyle().Faint(true).Italic(true)
)

// Tracker styles.
var (
	inactiveWorkerTitleStyle = lipgloss.NewStyle()
	selectedWorkerTitleStyle = lipgloss.NewStyle().Bold(true)
)

// Claude state dot styles — colored indicators for Claude activity state.
var (
	claudeStateActiveStyle  = lipgloss.NewStyle().Foreground(lipgloss.Color("#a3be8c"))
	claudeStateWaitingStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("#ebcb8b"))
	claudeStateDimStyle     = lipgloss.NewStyle().Foreground(lipgloss.Color("#555555")) // idle + done
)

// Status bar and key badge styles.
var (
	statusBarStyle      = lipgloss.NewStyle().Background(StatusBg).Foreground(StatusFg)
	statusBarErrorStyle = lipgloss.NewStyle().Background(Error).Foreground(BrightText)
	keyBadgeStyle       = lipgloss.NewStyle().Background(StatusBg).Foreground(BrightText).Padding(0, 1)
	keyLabelStyle       = lipgloss.NewStyle().Foreground(Muted)
	segmentSepStyle     = lipgloss.NewStyle().Foreground(DividerFg)
	spinnerStyle        = lipgloss.NewStyle().Bold(true)
)

// Snippet styles — Faint, below inactive titles in the hierarchy.
var (
	snippetStyleWide   = lipgloss.NewStyle().Faint(true).PaddingLeft(3)
	snippetStyleNarrow = lipgloss.NewStyle().Faint(true).PaddingLeft(2)
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

// Display labels — single source of truth for user-facing strings.
const (
	LabelMaster   = "Master"
	LabelWorker   = "Worker"
	LabelWizard   = "Wizard"
	LabelEvidence = "Evidence"
)
