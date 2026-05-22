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
)

// tmuxInactiveBorder is the exact hex used by tmux's `pane-border-style`
// (see dotfiles/.tmux.conf). The tracker's title separator sits directly
// under a tmux border at runtime, so we anchor its color here so the two
// lines render as a single continuous rule instead of two close-but-not-
// matching greys.
const tmuxInactiveBorder = lipgloss.Color("#373e47")

// Pane and title styles.
var (
	paneTitleStyle       = lipgloss.NewStyle().Foreground(Accent).Bold(true)
	inactiveBorderStyle  = lipgloss.NewStyle().Foreground(Muted)
	activeBorderStyle    = lipgloss.NewStyle().Foreground(Accent)
	scrollIndicatorStyle = lipgloss.NewStyle().Foreground(BrightText)
	dividerLineStyle     = lipgloss.NewStyle().Foreground(tmuxInactiveBorder)
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
	sessionTitleStyle     = lipgloss.NewStyle()
	stoppedGlyphStyle     = lipgloss.NewStyle().Foreground(Muted)
	currentIndicatorStyle = lipgloss.NewStyle().Foreground(Accent)
	currentSessionStyle   = lipgloss.NewStyle().Bold(true)
	// Tree trunks and non-selected box borders share the same muted color
	// as tmux's inactive pane border and the tracker header separators so
	// the whole chrome reads as one layer.
	treeGutterStyle       = lipgloss.NewStyle().Foreground(DividerBorder)
	snippetBarStyle       = lipgloss.NewStyle().Foreground(Muted)
	snippetTextStyle      = lipgloss.NewStyle().Italic(true)
	metaTextStyle         = lipgloss.NewStyle().Faint(true)
	sessionBoxBorderStyle = lipgloss.NewStyle().Foreground(DividerBorder)
	// Brighter than inactive, matches gh-dash's focused feel (GitHub fg.muted).
	selectedBoxBorderStyle = lipgloss.NewStyle().Foreground(palette.SelectedBoxBorder)
	selectedRowStyle       = lipgloss.NewStyle().Background(palette.SelectedRowBg)
)

// 7-state status styles. The activity icon now carries the agent identity
// (see agentIdentityStyle); the per-state foreground here drives the new
// status glyph and word. Standard ANSI codes so the terminal theme picks
// the actual hue.
var (
	workingGlyphStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("11"))
	blockedGlyphStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("9")).Bold(true)
	doneGlyphStyle    = lipgloss.NewStyle().Foreground(lipgloss.Color("10"))
	idleGlyphStyle    = lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
)

// agentIdentityStyle returns the activity-icon style for an agent. The icon
// always carries the agent identity (Claude coral / Codex blue / Pi purple)
// regardless of session role, so a glance at the dot identifies the engine
// driving the row. Unknown agents fall back to the muted session-title
// style so the row still renders.
func agentIdentityStyle(agent string) lipgloss.Style {
	switch agent {
	case "claude":
		return lipgloss.NewStyle().Foreground(palette.ClaudeColor)
	case "codex":
		return lipgloss.NewStyle().Foreground(palette.CodexColor)
	case "pi":
		return lipgloss.NewStyle().Foreground(palette.PiColor)
	default:
		return sessionTitleStyle
	}
}

// titleStyleForRow returns the title style for a session row. Per-row
// titles render in the terminal's default foreground — agent identity is
// already carried by the leading activity icon, so the title stays neutral
// to avoid double-signaling. The current row (the pane being viewed) gets
// Bold+Underline; the cursor-selected row gets Bold only. Underline is an
// SGR attribute drawn within the cell, so it does not change line height.
func titleStyleForRow(_ string, selected, isCurrent bool) lipgloss.Style {
	if isCurrent {
		return sessionTitleStyle.Bold(true).Underline(true)
	}
	if selected {
		return sessionTitleStyle.Bold(true)
	}
	return sessionTitleStyle
}

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
)
