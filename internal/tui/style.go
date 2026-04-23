package tui

import (
	"github.com/charmbracelet/lipgloss"

	"github.com/anthropics/ai-party/tools/party-cli/internal/palette"
)

// Semantic color tokens — mirrors scry's vocabulary (~/Code/scry/internal/ui/theme/theme.go).
// All use standard ANSI codes so the terminal theme decides actual RGB.
var (
	// Diff semantics.
	Added      = palette.Added
	Deleted    = palette.Deleted
	HunkHeader = palette.HunkHeader

	// Status semantics.
	Clean = palette.Clean // green — same hue as diff additions
	Dirty = palette.Warn
	Error = palette.Error

	// Chrome.
	Accent     = palette.Accent
	Muted      = palette.Muted
	StatusBg   = palette.StatusBg
	StatusFg   = palette.StatusFg
	DividerFg  = palette.DividerFg
	BrightText = palette.BrightText

	// Divider color — matches gh-dash's rendered border (GitHub border.muted).
	DividerBorder = palette.DividerBorder

	// party-cli-specific exception: gold for master identity text only.
	gold = palette.MasterRole
)

// Pane and title styles.
var (
	paneTitleStyle       = lipgloss.NewStyle().Foreground(Accent).Bold(true)
	inactiveBorderStyle  = lipgloss.NewStyle().Foreground(Muted)
	activeBorderStyle    = lipgloss.NewStyle().Foreground(Accent)
	scrollIndicatorStyle = lipgloss.NewStyle().Foreground(BrightText)
	dividerLineStyle     = lipgloss.NewStyle().Foreground(DividerBorder)
)

// Shared semantic tiers — inherit terminal foreground, use Bold/Faint for hierarchy.
var (
	sidebarLabelStyle = lipgloss.NewStyle().Bold(true)
	sidebarValueStyle = lipgloss.NewStyle().Faint(true)
	sidebarHelpStyle  = lipgloss.NewStyle().Faint(true)
)

// Text styles with semantic meaning.
var (
	activeTextStyle = lipgloss.NewStyle().Foreground(Clean)
	warnTextStyle   = lipgloss.NewStyle().Foreground(Dirty)
	errorTextStyle  = lipgloss.NewStyle().Foreground(Error)
	dimTextStyle    = lipgloss.NewStyle().Faint(true)
	noteTextStyle   = lipgloss.NewStyle().Faint(true).Italic(true)
)

// Tracker styles.
var (
	sessionTitleStyle         = lipgloss.NewStyle()
	selectedSessionTitleStyle = lipgloss.NewStyle().Bold(true)
	currentSessionTitleStyle  = lipgloss.NewStyle().Foreground(Accent).Bold(true)
	masterGlyphStyle          = lipgloss.NewStyle().Foreground(gold)
	workerGlyphStyle          = lipgloss.NewStyle().Foreground(palette.WorkerRole)
	standaloneGlyphStyle      = lipgloss.NewStyle().Foreground(palette.StandaloneRole)
	stoppedGlyphStyle         = lipgloss.NewStyle().Foreground(Muted)
	currentIndicatorStyle     = lipgloss.NewStyle().Foreground(Accent)
	currentSessionStyle       = lipgloss.NewStyle().Bold(true)
	// Tree trunks and non-selected box borders share the same muted color
	// as tmux's inactive pane border and the tracker header separators so
	// the whole chrome reads as one layer.
	treeGutterStyle       = lipgloss.NewStyle().Foreground(DividerBorder)
	snippetBarStyle       = lipgloss.NewStyle().Foreground(Muted)
	snippetTextStyle      = lipgloss.NewStyle().Italic(true)
	todoOverlayStyle      = lipgloss.NewStyle().Faint(true)
	metaTextStyle         = lipgloss.NewStyle().Faint(true)
	sessionBoxBorderStyle = lipgloss.NewStyle().Foreground(DividerBorder)
	// Brighter than inactive, matches gh-dash's focused feel (GitHub fg.muted).
	selectedBoxBorderStyle = lipgloss.NewStyle().Foreground(palette.SelectedBoxBorder)
	selectedRowStyle       = lipgloss.NewStyle().Background(palette.SelectedRowBg)
)

// dimActivityStyle renders the activity dot's "blink off" half — a muted
// grey that the identity-coloured dot alternates with while the agent is
// generating.
var (
	dimActivityStyle = lipgloss.NewStyle().Foreground(palette.ActivityDim)
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

// Width and height thresholds.
const (
	compactHeightThreshold = 14
)

// Display labels — single source of truth for user-facing strings.
const (
	LabelMaster     = "Master"
	LabelWorker     = "Worker"
	LabelStandalone = "Standalone"
	LabelCompanion  = "Companion"
	LabelEvidence   = "Evidence"
)
