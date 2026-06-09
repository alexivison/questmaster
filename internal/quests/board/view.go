package board

import (
	"strings"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"

	"github.com/alexivison/questmaster/internal/palette"
	"github.com/alexivison/questmaster/internal/quests/quest"
)

var (
	// projectHeaderStyle paints the project section headers in the detail view's
	// section colour (yellowish), since projects now head the log's sections.
	projectHeaderStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("#e6b860"))
	dividerStyle       = lipgloss.NewStyle().Foreground(lipgloss.Color("#3a4354"))
	// vDividerStyle (list|detail splitter) shares the header separator's colour.
	vDividerStyle = dividerStyle
	// titleStyle matches the tracker's title: bold, default foreground.
	titleStyle = lipgloss.NewStyle().Bold(true)
	footStyle  = lipgloss.NewStyle().Foreground(lipgloss.Color("#5a6577"))
	errStyle   = lipgloss.NewStyle().Foreground(lipgloss.Color("#e0906f"))
	// rowSelectedStyle is the cursor highlight — a full-width background tint
	// like the tracker's selected row.
	rowSelectedStyle = lipgloss.NewStyle().Background(palette.SelectedRowBg)
)

const (
	boardHeaderHeight = 2 // title bar + divider
	boardFooterHeight = 1
	listMinWidth      = 26
	// listPadLeft mirrors the detail pane's gutter so both panes share the same
	// left margin.
	listPadLeft = 1
)

// View renders the two-pane board: a grouped list on the left, the selected
// quest's detail (RenderDetail) in a scrollable viewport on the right.
func (m Model) View() string {
	if m.width == 0 || m.height == 0 {
		return ""
	}

	listW := m.width * 34 / 100
	if listW < listMinWidth {
		listW = listMinWidth
	}
	if listW > m.width-20 {
		listW = max(listMinWidth, m.width-20)
	}
	detailW := m.width - listW - 1 // 1 col for the divider
	if detailW < 1 {
		detailW = 1
	}

	bodyH := m.height - boardHeaderHeight - boardFooterHeight
	if bodyH < 1 {
		bodyH = 1
	}

	bar := titleStyle.Render(" Quests ")
	divider := dividerStyle.Render(strings.Repeat("─", m.width))

	left := m.renderList(listW, bodyH)
	right := m.renderDetail(detailW, bodyH)
	vline := strings.TrimRight(strings.Repeat(vDividerStyle.Render("│")+"\n", bodyH), "\n")
	body := lipgloss.JoinHorizontal(lipgloss.Top, left, vline, right)

	foot := footStyle.Render(m.footHint())
	if m.lastErr != nil {
		foot = errStyle.Render(ansi.Truncate(m.lastErr.Error(), m.width, "…"))
	}

	return bar + "\n" + divider + "\n" + body + "\n" + foot
}

// footHint is the keymap line, context-sensitive to which pane has focus.
func (m Model) footHint() string {
	loopNote := ""
	if q, ok := m.Selected(); ok {
		if rt := m.runtimeOf(q.ID); rt.Loop != nil {
			loopNote = " · " + rt.Loop.Label() + " armed"
		}
	}
	if m.focus == focusDetail {
		return "↑↓ row · space toggle · o open link · r refresh · ← back · q quit" + loopNote
	}
	return "↑↓ move · → details · o open · e edit · c check · r refresh · a board · w draft · d done · q quit" + loopNote
}

// renderList renders the grouped rows with a left gutter and top breathing room
// (matching the detail pane), scrolled to keep the cursor visible. The cursor
// row is a full-width background highlight, like the tracker.
func (m Model) renderList(width, height int) string {
	gutter := strings.Repeat(" ", listPadLeft)
	var lines []string
	cursorLine := 0
	idx := 0 // running quest index across groups, matching m.cursor
	for _, g := range m.Groups() {
		lines = append(lines, projectHeaderStyle.Render(fitLeft(gutter+g.Label, width)))
		for i := range g.Quests {
			q := g.Quests[i]
			selected := idx == m.cursor
			if selected {
				cursorLine = len(lines) + 1
			}
			row := quest.RenderListRow(&q, m.runtimeOf(q.ID), max(1, width-listPadLeft))
			if selected {
				lines = append(lines, selectedBlankRow(width))
				lines = append(lines, selectedRow(gutter+row, width))
				lines = append(lines, selectedBlankRow(width))
			} else {
				lines = append(lines, "")
				lines = append(lines, fitLeft(gutter+row, width))
				lines = append(lines, "")
			}
			idx++
		}
	}
	if len(lines) == 0 {
		lines = append(lines, projectHeaderStyle.Render(fitLeft(gutter+"No quests.", width)))
	}
	return strings.Join(scrollWindow(lines, cursorLine, height), "\n")
}

// detailPadLeft / detailPadRight keep the detail content off the divider and
// the right edge; a leading blank line gives it top breathing room.
const (
	detailPadLeft  = 1
	detailPadRight = 1
)

// renderDetail renders the selected quest's detail pane, scrolled by
// detailScroll, with an outer gutter, padded/clipped to the viewport.
func (m Model) renderDetail(width, height int) string {
	q, ok := m.Selected()
	if !ok {
		return strings.Join(padTo(nil, height), "\n")
	}
	inner := width - detailPadLeft - detailPadRight
	if inner < 1 {
		inner = 1
	}
	gutter := strings.Repeat(" ", detailPadLeft)
	rt := m.runtimeOf(q.ID)
	detailLines, focusedLine := quest.RenderDetailLines(&q, rt, inner, m.detailFocus())

	lines := make([]string, 0, len(detailLines))
	for i, ln := range detailLines {
		if i == focusedLine {
			// Same full-width selection background as the list's cursor row.
			lines = append(lines, selectedRow(gutter+ln, width))
		} else {
			lines = append(lines, gutter+ln)
		}
	}

	start := m.detailScroll
	// When the detail pane has focus, follow the cursor: keep the focused row
	// inside the viewport (the list pane scrolls the same way). Manual
	// ctrl+f/ctrl+b scroll still applies while the focused row stays visible.
	if focusedLine >= 0 {
		if focusedLine < start {
			start = focusedLine
		} else if focusedLine >= start+height {
			start = focusedLine - height + 1
		}
	}
	if start > len(lines)-1 {
		start = max(0, len(lines)-1)
	}
	if start < 0 {
		start = 0
	}
	visible := lines[start:]
	if len(visible) > height {
		visible = visible[:height]
	}
	return strings.Join(padTo(visible, height), "\n")
}

// scrollWindow returns a height-tall slice of lines that keeps cursorLine
// visible, padding short lists.
func scrollWindow(lines []string, cursorLine, height int) []string {
	if len(lines) <= height {
		return padTo(lines, height)
	}
	start := 0
	if cursorLine >= height {
		start = cursorLine - height + 1
	}
	if start+height > len(lines) {
		start = len(lines) - height
	}
	return lines[start : start+height]
}

func padTo(lines []string, height int) []string {
	out := append([]string(nil), lines...)
	for len(out) < height {
		out = append(out, "")
	}
	return out
}

// fitLeft pads or truncates a styled string to exactly width columns.
func fitLeft(s string, width int) string {
	w := lipgloss.Width(s)
	if w > width {
		return ansi.Truncate(s, width, "")
	}
	if w < width {
		return s + strings.Repeat(" ", width-w)
	}
	return s
}

func selectedBlankRow(width int) string {
	return rowSelectedStyle.Width(width).Render("")
}

func selectedRow(s string, width int) string {
	return applySelectedBackground(fitLeft(s, width))
}

func applySelectedBackground(s string) string {
	marker := rowSelectedStyle.Render("x")
	idx := strings.Index(marker, "x")
	if idx < 0 {
		return s
	}
	bgSeq := marker[:idx]
	var b strings.Builder
	b.WriteString(bgSeq)
	for i := 0; i < len(s); {
		if s[i] == '\x1b' {
			j := i + 1
			for j < len(s) && s[j] != 'm' {
				j++
			}
			if j < len(s) {
				b.WriteString(s[i : j+1])
				b.WriteString(bgSeq)
				i = j + 1
				continue
			}
		}
		b.WriteByte(s[i])
		i++
	}
	b.WriteString("\x1b[0m")
	return b.String()
}
