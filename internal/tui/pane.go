package tui

import (
	"strings"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

// keyHint pairs a key name with a short label for status bar badges.
type keyHint struct {
	Key   string
	Label string
}

// borderedPane wraps content in a rounded border with an optional title and footer.
// outerWidth and outerHeight are total dimensions including borders.
// When active is true the border uses Accent; otherwise Muted.
func borderedPane(content, title, footer string, outerWidth, outerHeight int, active bool) string {
	return borderedPaneWithScroll(content, title, footer, outerWidth, outerHeight, active, -1)
}

// borderedPaneWithScroll is like borderedPane but highlights a right-border segment
// as a scroll indicator. scrollLine is the 0-based inner row to highlight; negative
// means no indicator.
func borderedPaneWithScroll(content, title, footer string, outerWidth, outerHeight int, active bool, scrollLine int) string {
	if outerWidth < 4 || outerHeight < 3 {
		return content
	}

	borderColor := Muted
	if active {
		borderColor = Accent
	}
	colorStyle := lipgloss.NewStyle().Foreground(borderColor)
	scrollStyle := scrollIndicatorStyle

	innerWidth := outerWidth - 2

	top := buildBorderLine("╭", "╮", "─", title, innerWidth, colorStyle)
	bottom := buildBorderLine("╰", "╯", "─", footer, innerWidth, colorStyle)

	innerHeight := outerHeight - 2
	contentLines := strings.Split(content, "\n")
	rows := make([]string, innerHeight)
	side := colorStyle.Render("│")
	for i := range innerHeight {
		var line string
		if i < len(contentLines) {
			line = contentLines[i]
		}
		rightSide := side
		if i == scrollLine {
			rightSide = scrollStyle.Render("┃")
		}
		rows[i] = side + padOrTruncate(line, innerWidth) + rightSide
	}

	parts := make([]string, 0, outerHeight)
	parts = append(parts, top)
	parts = append(parts, rows...)
	parts = append(parts, bottom)
	return strings.Join(parts, "\n")
}

// buildBorderLine constructs a top or bottom border line with an embedded label.
// Example: ╭─ Files ──────────╮
func buildBorderLine(left, right, fill, label string, innerWidth int, style lipgloss.Style) string {
	if label == "" {
		return style.Render(left + strings.Repeat(fill, innerWidth) + right)
	}

	maxLabel := innerWidth - 3 // fill + space + label + space
	if maxLabel < 1 {
		return style.Render(left + strings.Repeat(fill, innerWidth) + right)
	}
	if lipgloss.Width(label) > maxLabel {
		label = ansi.Truncate(label, maxLabel-1, "") + "…"
	}

	decorated := fill + " " + label + " "
	remaining := innerWidth - lipgloss.Width(decorated)
	if remaining < 0 {
		remaining = 0
	}
	return style.Render(left + decorated + strings.Repeat(fill, remaining) + right)
}

// padOrTruncate ensures a string fits exactly within the given visual width.
func padOrTruncate(s string, width int) string {
	w := lipgloss.Width(s)
	if w == width {
		return s
	}
	if w > width {
		return ansi.Truncate(s, width, "")
	}
	return s + strings.Repeat(" ", width-w)
}

// contentDimensions returns the inner width and height available for content
// inside a bordered pane. Values are clamped to ≥0.
func contentDimensions(outerWidth, outerHeight int) (int, int) {
	w := outerWidth - 2
	h := outerHeight - 2
	if w < 0 {
		w = 0
	}
	if h < 0 {
		h = 0
	}
	return w, h
}

// chromeLayout decides footer-only vs pane+status-bar body budgets.
// Returns the body height available for content and whether a status bar should render.
func chromeLayout(totalHeight int, wantsStatusBar bool) (bodyHeight int, showStatusBar bool) {
	if wantsStatusBar && totalHeight >= compactHeightThreshold {
		h := totalHeight - 3
		if h < 0 {
			h = 0
		}
		return h, true
	}
	h := totalHeight - 2
	if h < 0 {
		h = 0
	}
	return h, false
}

// renderStatusBar renders a full-width, single-row status bar for transient messages.
// Error takes priority over message; key badges render when neither is present.
// Content is truncated to fit within width so the bar never wraps.
func renderStatusBar(width int, hints []keyHint, message string, err error) string {
	if err != nil {
		return statusBarErrorStyle.Render(fitBar(" "+err.Error(), width))
	}
	if message != "" {
		return statusBarStyle.Render(fitBar(" "+message, width))
	}
	if len(hints) == 0 {
		return statusBarStyle.Render(strings.Repeat(" ", width))
	}

	var badges []string
	for _, h := range hints {
		badge := keyBadgeStyle.Render(h.Key) + " " + keyLabelStyle.Render(h.Label)
		badges = append(badges, badge)
	}
	return statusBarStyle.Render(fitBar(" "+strings.Join(badges, "  "), width))
}

// fitBar truncates or pads a bar string to exactly the given visual width.
func fitBar(s string, width int) string {
	w := lipgloss.Width(s)
	if w > width {
		return ansi.Truncate(s, width, "")
	}
	if w < width {
		return s + strings.Repeat(" ", width-w)
	}
	return s
}
