package board

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"

	"github.com/alexivison/questmaster/internal/palette"
	"github.com/alexivison/questmaster/internal/quests/quest"
)

var (
	// projectHeaderStyle paints the project section name in the detail view's
	// section colour (yellowish), since projects now head the log's sections.
	projectHeaderStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("#e6b860"))
	// projectRuleStyle dims the horizontal rule flanking the project name
	// (#5a6577 — the same dim the non-active list ids use).
	projectRuleStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("#5a6577"))
	dividerStyle     = lipgloss.NewStyle().Foreground(lipgloss.Color("#3a4354"))
	// vDividerStyle (list|detail splitter) shares the header separator's colour.
	vDividerStyle = dividerStyle
	// titleStyle matches the tracker's title: bold, default foreground.
	titleStyle = lipgloss.NewStyle().Bold(true)
	footStyle  = lipgloss.NewStyle().Foreground(lipgloss.Color("#5a6577"))
	errStyle   = lipgloss.NewStyle().Foreground(lipgloss.Color("#e0906f"))
	// rowSelectedStyle is the cursor highlight — a full-width background tint
	// like the tracker's selected row.
	rowSelectedStyle    = lipgloss.NewStyle().Background(palette.SelectedRowBg)
	composerBorderStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("#3a4354"))
	composerTextStyle   = lipgloss.NewStyle().Foreground(lipgloss.Color("#dbe4f1"))
	composerKeyStyle    = lipgloss.NewStyle().Foreground(lipgloss.Color("#4ec3d6"))
	// tab bar: the selected tab is bright, the rest dim, separated by a faint dot.
	tabSelectedStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("#eef3fb")).Bold(true)
	tabDimStyle      = lipgloss.NewStyle().Foreground(lipgloss.Color("#5a6577"))
	tabSepStyle      = lipgloss.NewStyle().Foreground(lipgloss.Color("#3a4354"))
)

const (
	boardHeaderHeight = 3 // title bar + divider + tab bar
	boardFooterHeight = 1
	listMinWidth      = 26
	// listPadLeft mirrors the detail pane's gutter so both panes share the same
	// left margin. listPadRight insets the right edge by the same amount so the
	// row's tag is not flush against the list|detail divider.
	listPadLeft  = 1
	listPadRight = listPadLeft
)

// View renders the two-pane board: a grouped list on the left, the selected
// quest's detail (RenderDetail) in a scrollable viewport on the right.
func (m Model) View() string {
	if m.width == 0 || m.height == 0 {
		return ""
	}

	listW, detailW := paneWidths(m.width)

	bodyH := m.height - boardHeaderHeight - boardFooterHeight
	if bodyH < 1 {
		bodyH = 1
	}

	bar := titleStyle.Render(" Quests ")
	divider := dividerStyle.Render(strings.Repeat("─", m.width))
	tabs := m.tabBar(m.width)

	left := m.renderList(listW, bodyH)
	right := m.renderDetail(detailW, bodyH)
	vline := strings.TrimRight(strings.Repeat(vDividerStyle.Render("│")+"\n", bodyH), "\n")
	body := lipgloss.JoinHorizontal(lipgloss.Top, left, vline, right)

	foot := footStyle.Render(m.footHint())
	if m.lastErr != nil {
		foot = errStyle.Render(ansi.Truncate(m.lastErr.Error(), m.width, "…"))
	}

	return bar + "\n" + divider + "\n" + tabs + "\n" + body + "\n" + foot
}

// tabBar renders the one-line status tab bar — "Drafts (n) · Active (n) ·
// Done (n)" — with the selected tab bright and the others dim. Counts come from
// the full store set, not the visible tab. Fits width.
func (m Model) tabBar(width int) string {
	counts := m.tabCounts()
	segs := make([]string, len(tabDefs))
	for i, d := range tabDefs {
		label := fmt.Sprintf("%s (%d)", d.label, counts[d.tab])
		if d.tab == m.tab {
			segs[i] = tabSelectedStyle.Render(label)
		} else {
			segs[i] = tabDimStyle.Render(label)
		}
	}
	return fitLeft(" "+strings.Join(segs, tabSepStyle.Render(" · ")), width)
}

// tabCounts tallies quests per tab from the full store set.
func (m Model) tabCounts() map[statusTab]int {
	counts := make(map[statusTab]int, len(tabDefs))
	for _, q := range m.quests {
		for _, d := range tabDefs {
			if q.Status == d.status {
				counts[d.tab]++
			}
		}
	}
	return counts
}

// footHint is the keymap line, context-sensitive to which pane has focus.
func (m Model) footHint() string {
	loopNote := ""
	if q, ok := m.Selected(); ok {
		if rt := m.runtimeOf(q.ID); rt.Loop != nil {
			loopNote = " · " + rt.Loop.Label()
			if rt.Loop.Phase == "" {
				// Pre-phase markers say nothing about liveness; keep the
				// explicit "armed" tag for them.
				loopNote += " armed"
			}
		}
	}
	if m.composer != nil {
		return "enter post · alt+enter/ctrl+j newline · esc cancel" + loopNote
	}
	if m.focus == focusDetail {
		if len(m.detailTargets()) <= 1 {
			return "↑↓/pgup/pgdn scroll · m comment · r refresh · ← back · q quit" + loopNote
		}
		return "↑↓ row · pgup/pgdn scroll · m comment · R resolve · space toggle · o open link · r refresh · ← back · q quit" + loopNote
	}
	return "↑↓ move · ⇥ tabs · → details · pgup/pgdn detail · o open · e edit · c check · r refresh · a board · w draft · d done · x delete · q quit" + loopNote
}

// renderList renders the grouped rows with a left gutter, scrolled to keep the
// cursor visible. The cursor row is a full-width background highlight, like the
// tracker.
func (m Model) renderList(width, height int) string {
	gutter := strings.Repeat(" ", listPadLeft)
	var lines []string
	cursorLine := 0
	idx := 0 // running quest index across groups, matching m.cursor
	for _, g := range m.Groups() {
		lines = append(lines, projectHeader(g.Label, width))
		for i := range g.Quests {
			q := g.Quests[i]
			selected := idx == m.cursor
			if selected {
				cursorLine = len(lines) + 1
			}
			rows := quest.RenderBoardListRows(&q, m.runtimeOf(q.ID), max(1, width-listPadLeft-listPadRight))
			if selected {
				for _, row := range rows {
					lines = append(lines, selectedRow(gutter+row, width))
				}
			} else {
				for _, row := range rows {
					lines = append(lines, fitLeft(gutter+row, width))
				}
			}
			idx++
		}
	}
	if len(lines) == 0 {
		lines = append(lines, projectHeaderStyle.Render(fitLeft(gutter+"No quests.", width)))
	}
	return strings.Join(scrollWindow(lines, cursorLine, height), "\n")
}

// projectHeaderLead is the rule segment drawn before a project name.
const projectHeaderLead = 2

// projectHeader renders a project section header as a single full-width rule:
// a short leading rule, the (yellow) project name, then a dim rule filling to
// the right edge — "── name ─────────". Exactly width columns and one line, so
// the cursor/scroll math in renderList stays valid.
func projectHeader(name string, width int) string {
	used := projectHeaderLead + 1 + lipgloss.Width(name) + 1 // "──" + " " + name + " "
	if used >= width {
		// Too narrow for a trailing rule; show as much of the name as fits.
		return projectHeaderStyle.Render(fitLeft(name, width))
	}
	rule := func(n int) string { return projectRuleStyle.Render(strings.Repeat("─", n)) }
	return rule(projectHeaderLead) + " " + projectHeaderStyle.Render(name) + " " + rule(width-used)
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
	detailLines, selection := quest.RenderDetailLineSelection(&q, rt, inner, m.detailFocus())
	focusedLine := selection.Primary

	lines := make([]string, 0, len(detailLines))
	for i, ln := range detailLines {
		if selection.Contains(i) {
			// Same full-width selection background as the list's cursor row.
			lines = append(lines, selectedRow(gutter+ln, width))
		} else {
			lines = append(lines, gutter+ln)
		}
	}

	start := m.detailScroll
	// When the detail pane has focus, follow the cursor: keep the focused row
	// inside the viewport (the list pane scrolls the same way). Explicit detail
	// scrolling temporarily decouples the viewport from the focused row.
	if focusedLine >= 0 && !m.detailManualScroll {
		if focusedLine < start {
			start = focusedLine
		} else if focusedLine >= start+height {
			start = focusedLine - height + 1
		}
	}
	start = clampDetailStart(start, len(lines), height)
	var composerLines []string
	if m.composer != nil {
		composerLines = m.composerPanelLines(width)
		if focusedLine >= 0 && len(composerLines) < height {
			maxFocusedRel := height - len(composerLines) - 1
			if maxFocusedRel < 0 {
				maxFocusedRel = 0
			}
			if focusedLine-start > maxFocusedRel {
				start = focusedLine - maxFocusedRel
				start = clampDetailStart(start, len(lines), height)
			}
		}
	}
	visible := lines[start:]
	if len(visible) > height {
		visible = visible[:height]
	}
	visible = padTo(visible, height)
	if m.composer != nil {
		visible = m.renderComposerPanel(visible, focusedLine-start, composerLines)
	}
	return strings.Join(visible, "\n")
}

func (m Model) renderComposerPanel(base []string, focusedLine int, panel []string) []string {
	if m.composer == nil || len(base) == 0 || len(panel) == 0 {
		return base
	}
	insertAt := 0
	if focusedLine >= 0 && focusedLine < len(base) {
		insertAt = focusedLine + 1
	}
	out := make([]string, 0, len(base)+len(panel))
	out = append(out, base[:insertAt]...)
	out = append(out, panel...)
	out = append(out, base[insertAt:]...)
	if len(out) > len(base) {
		out = out[:len(base)]
	}
	return out
}

func (m Model) composerPanelLines(width int) []string {
	c := m.composer
	if c == nil {
		return nil
	}
	panelWidth := width - 6
	if panelWidth > 78 {
		panelWidth = 78
	}
	if panelWidth < 34 {
		panelWidth = max(12, width-2)
	}
	leftPad := 3
	if leftPad+panelWidth > width {
		leftPad = max(0, width-panelWidth)
	}
	pad := strings.Repeat(" ", leftPad)
	inner := max(1, panelWidth-2)
	textareaTextWidth := max(1, inner-6)
	editor := c.Editor
	editor.SetWidth(textareaTextWidth)
	editor.SetHeight(6)

	line := func(s string) string { return fitLeft(pad+s, width) }
	rule := func(left, right string) string {
		return line(composerBorderStyle.Render(left + strings.Repeat("─", inner) + right))
	}
	content := func(s string) string {
		return line(composerBorderStyle.Render("│") + fitLeft(s, inner) + composerBorderStyle.Render("│"))
	}
	title := composerTextStyle.Render(" new comment")

	lines := []string{
		rule("╭", "╮"),
		content(title),
		rule("├", "┤"),
		content(" " + composerBorderStyle.Render("╭"+strings.Repeat("─", textareaTextWidth+2)+"╮") + " "),
	}
	editorLines := strings.Split(editor.View(), "\n")
	if len(editorLines) > 6 {
		editorLines = editorLines[:6]
	}
	editorLines = padTo(editorLines, 6)
	for _, ln := range editorLines {
		lines = append(lines, content(" "+composerBorderStyle.Render("│")+" "+fitLeft(ln, textareaTextWidth)+" "+composerBorderStyle.Render("│")+" "))
	}
	lines = append(lines,
		content(" "+composerBorderStyle.Render("╰"+strings.Repeat("─", textareaTextWidth+2)+"╯")+" "),
		content(""),
		content(" "+composerKeyStyle.Render("enter")+" post  "+composerKeyStyle.Render("alt+enter")+" newline  "+composerKeyStyle.Render("ctrl+j")+" newline  "+composerKeyStyle.Render("esc")+" cancel"),
		rule("╰", "╯"),
	)
	return lines
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

func paneWidths(width int) (int, int) {
	listW := width * 34 / 100
	if listW < listMinWidth {
		listW = listMinWidth
	}
	if listW > width-20 {
		listW = max(listMinWidth, width-20)
	}
	detailW := width - listW - 1 // 1 col for the divider
	if detailW < 1 {
		detailW = 1
	}
	return listW, detailW
}

func clampDetailStart(start, lineCount, height int) int {
	if height < 1 {
		height = 1
	}
	maxStart := lineCount - height
	if maxStart < 0 {
		maxStart = 0
	}
	if start > maxStart {
		return maxStart
	}
	if start < 0 {
		return 0
	}
	return start
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
