package board

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"

	"github.com/alexivison/questmaster/internal/quests/quest"
)

var (
	groupHeaderStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("#5a6577"))
	cursorMarkStyle  = lipgloss.NewStyle().Foreground(lipgloss.Color("#4ec3d6"))
	dividerStyle     = lipgloss.NewStyle().Foreground(lipgloss.Color("#222a38"))
	barStyle         = lipgloss.NewStyle().Foreground(lipgloss.Color("#5a6577"))
	footStyle        = lipgloss.NewStyle().Foreground(lipgloss.Color("#5a6577"))
	errStyle         = lipgloss.NewStyle().Foreground(lipgloss.Color("#e0906f"))
)

const (
	boardHeaderHeight = 2 // title bar + divider
	boardFooterHeight = 1
	listMinWidth      = 26
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

	bar := barStyle.Render(fmt.Sprintf("quest log — %s", m.counts()))
	divider := dividerStyle.Render(strings.Repeat("─", m.width))

	left := m.renderList(listW, bodyH)
	right := m.renderDetail(detailW, bodyH)
	vline := strings.TrimRight(strings.Repeat(dividerStyle.Render("│")+"\n", bodyH), "\n")
	body := lipgloss.JoinHorizontal(lipgloss.Top, left, vline, right)

	foot := footStyle.Render("↑↓ move · ↵ open · e edit · a approve · d done · ^f/^b scroll · q quit")
	if m.lastErr != nil {
		foot = errStyle.Render(ansi.Truncate(m.lastErr.Error(), m.width, "…"))
	}

	return bar + "\n" + divider + "\n" + body + "\n" + foot
}

func (m Model) counts() string {
	var active, wip, done int
	for _, q := range m.quests {
		switch q.Status {
		case quest.StatusActive:
			active++
		case quest.StatusWIP:
			wip++
		case quest.StatusDone:
			done++
		}
	}
	return fmt.Sprintf("%d active · %d wip · %d done", active, wip, done)
}

// renderList renders the grouped rows, scrolled to keep the cursor visible.
func (m Model) renderList(width, height int) string {
	var lines []string
	cursorLine := 0
	idx := 0 // running quest index across groups, matching m.cursor
	for _, g := range m.Groups() {
		lines = append(lines, groupHeaderStyle.Render(fitLeft(fmt.Sprintf("%s (%d)", g.Label, len(g.Quests)), width)))
		for i := range g.Quests {
			q := g.Quests[i]
			selected := idx == m.cursor
			if selected {
				cursorLine = len(lines)
			}
			mark := "  "
			if selected {
				mark = cursorMarkStyle.Render("▸ ")
			}
			row := quest.RenderListRow(&q, m.runtimeOf(q.ID), max(1, width-2))
			lines = append(lines, fitLeft(mark+row, width))
			idx++
		}
	}
	if len(lines) == 0 {
		lines = append(lines, groupHeaderStyle.Render(fitLeft("No quests.", width)))
	}
	return strings.Join(scrollWindow(lines, cursorLine, height), "\n")
}

// renderDetail renders the selected quest's detail pane, scrolled by
// detailScroll, padded/clipped to the viewport.
func (m Model) renderDetail(width, height int) string {
	q, ok := m.Selected()
	if !ok {
		return strings.Join(padTo(nil, height), "\n")
	}
	rt := m.runtimeOf(q.ID)
	detail := quest.RenderDetail(&q, rt, width)
	lines := strings.Split(detail, "\n")

	start := m.detailScroll
	if start > len(lines)-1 {
		start = max(0, len(lines)-1)
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
