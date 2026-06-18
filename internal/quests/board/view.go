package board

import (
	"fmt"
	"strings"
	"sync"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
	"github.com/muesli/termenv"

	"github.com/alexivison/questmaster/internal/palette"
	"github.com/alexivison/questmaster/internal/quests/quest"
)

var (
	// projectHeaderStyle paints the project section name in the detail view's
	// section colour (yellowish), since projects now head the log's sections.
	projectHeaderStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("#e6b860"))
	// projectRuleStyle uses the same border color as the rest of the board
	// chrome so project separators do not read as a separate tier.
	projectRuleStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("#3a4354"))
	dividerStyle     = lipgloss.NewStyle().Foreground(lipgloss.Color("#3a4354"))
	// vDividerStyle (list|detail splitter) shares the header separator's colour.
	vDividerStyle           = dividerStyle
	detailFocusDividerStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("#e6b860")).Bold(true)
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
//
// The frame is cached (B1): a poll tick or a no-op message re-enters View with
// identical state, and recomputing both panes every time is the board's main
// per-frame cost. The cache key pairs contentVersion (bumped by reload only on
// real change) with the view-state that the panes depend on. The composer is
// never cached — its textarea repaints on every keystroke without a reload.
func (m Model) View() string {
	if m.width == 0 || m.height == 0 {
		return ""
	}

	cacheable := m.composer == nil && m.frame != nil
	if cacheable {
		key := m.frameCacheKey()
		if m.frame.valid && m.frame.key == key {
			return m.frame.frame
		}
		frame := m.renderFrame()
		*m.frame = frameCacheBox{key: key, frame: frame, valid: true}
		return frame
	}
	return m.renderFrame()
}

func (m Model) frameCacheKey() frameCacheKey {
	key := frameCacheKey{
		version:            m.contentVersion,
		tab:                m.tab,
		cursor:             m.cursor,
		listScroll:         m.listScroll,
		detailCursor:       m.detailCursor,
		detailScroll:       m.detailScroll,
		detailManualScroll: m.detailManualScroll,
		focus:              m.focus,
		width:              m.width,
		height:             m.height,
	}
	if m.lastErr != nil {
		key.lastErr = m.lastErr.Error()
	}
	return key
}

func (m Model) renderFrame() string {
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
	body := lipgloss.JoinHorizontal(lipgloss.Top, left, verticalDivider(bodyH, m.focus == focusDetail), right)

	foot := footStyle.Render(m.footHint())
	if m.lastErr != nil {
		foot = errStyle.Render(ansi.Truncate(m.lastErr.Error(), m.width, "…"))
	}

	return bar + "\n" + divider + "\n" + tabs + "\n" + body + "\n" + foot
}

// verticalDivider builds the bodyH-tall list|detail splitter. The styled cell
// is rendered once (its SGR is invariant) and assembled with a pre-sized
// builder, instead of re-rendering and concatenating per line (B5).
func verticalDivider(bodyH int, focused bool) string {
	cell := verticalDividerCell(focused)
	var b strings.Builder
	b.Grow((len(cell) + 1) * bodyH)
	for i := 0; i < bodyH; i++ {
		if i > 0 {
			b.WriteByte('\n')
		}
		b.WriteString(cell)
	}
	return b.String()
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
			return "↑↓/pgup/pgdn scroll · ⇥ tabs · m comment · r refresh · ← back · q quit" + loopNote
		}
		return "↑↓ row · ⇥ tabs · pgup/pgdn scroll · m comment · e edit comment · D delete comment · R resolve · space toggle · o open link · r refresh · ← back · q quit" + loopNote
	}
	return "↑↓ move · ⇥ tabs · → details · pgup/pgdn detail · o open · e edit · c check · r refresh · a board · w draft · d done · x delete · q quit" + loopNote
}

// renderList renders the grouped rows with a left gutter, scrolled to keep the
// cursor visible. The cursor row is a full-width background highlight, like the
// tracker.
func (m Model) renderList(width, height int) string {
	gutter := strings.Repeat(" ", listPadLeft)
	var lines []string
	idx := 0 // running quest index across groups, matching m.cursor
	for _, g := range m.Groups() {
		lines = append(lines, projectHeader(g.Label, width))
		for i := range g.Quests {
			q := g.Quests[i]
			selected := idx == m.cursor
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
	start := clampDetailStart(m.listScroll, len(lines), height)
	visible := lines[start:]
	if len(visible) > height {
		visible = visible[:height]
	}
	return strings.Join(padTo(visible, height), "\n")
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

const composerTextareaHeight = 6

type composerPanelLayout struct {
	leftPad       int
	inner         int
	textareaWidth int
}

func composerPanelLayoutFor(width int) composerPanelLayout {
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
	inner := max(1, panelWidth-2)
	return composerPanelLayout{
		leftPad:       leftPad,
		inner:         inner,
		textareaWidth: max(1, inner-6),
	}
}

// renderDetail renders the selected quest's detail pane, scrolled by
// detailScroll, with an outer gutter, padded/clipped to the viewport.
func (m Model) renderDetail(width, height int) string {
	if _, ok := m.Selected(); !ok {
		return strings.Join(padTo(nil, height), "\n")
	}
	inner := width - detailPadLeft - detailPadRight
	if inner < 1 {
		inner = 1
	}
	gutter := strings.Repeat(" ", detailPadLeft)
	detailLines, selection := m.detailSelection(inner)
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
	layout := composerPanelLayoutFor(width)
	pad := strings.Repeat(" ", layout.leftPad)
	editor := c.Editor
	editor.SetWidth(layout.textareaWidth)
	editor.SetHeight(composerTextareaHeight)

	line := func(s string) string { return fitLeft(pad+s, width) }
	rule := func(left, right string) string {
		return line(composerBorderStyle.Render(left + strings.Repeat("─", layout.inner) + right))
	}
	content := func(s string) string {
		return line(composerBorderStyle.Render("│") + fitLeft(s, layout.inner) + composerBorderStyle.Render("│"))
	}
	titleText := " new comment"
	if c.CommentID != "" {
		titleText = " edit comment"
	}
	title := composerTextStyle.Render(titleText)

	lines := []string{
		rule("╭", "╮"),
		content(title),
		rule("├", "┤"),
		content(" " + composerBorderStyle.Render("╭"+strings.Repeat("─", layout.textareaWidth+2)+"╮") + " "),
	}
	editorLines := strings.Split(editor.View(), "\n")
	if len(editorLines) > composerTextareaHeight {
		editorLines = editorLines[:composerTextareaHeight]
	}
	editorLines = padTo(editorLines, composerTextareaHeight)
	for _, ln := range editorLines {
		lines = append(lines, content(" "+composerBorderStyle.Render("│")+" "+fitLeft(ln, layout.textareaWidth)+" "+composerBorderStyle.Render("│")+" "))
	}
	lines = append(lines,
		content(" "+composerBorderStyle.Render("╰"+strings.Repeat("─", layout.textareaWidth+2)+"╯")+" "),
		content(""),
		content(" "+composerKeyStyle.Render("enter")+" post  "+composerKeyStyle.Render("alt+enter")+" newline  "+composerKeyStyle.Render("ctrl+j")+" newline  "+composerKeyStyle.Render("esc")+" cancel"),
		rule("╰", "╯"),
	)
	return lines
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

// The selection-background SGR prefix and the styled vertical-divider cell both
// depend on lipgloss's detected colour profile, which is only known once
// rendering starts (and which tests flip with SetColorProfile). They are
// derived once and reused, re-derived only when the active profile changes —
// so applySelectedBackground no longer re-renders a throwaway Render("x") for
// every selected line, every frame (B3), while still honouring a profile switch.
var (
	styleCacheMu          sync.Mutex
	styleCacheProfile     termenv.Profile
	styleCacheInit        bool
	cachedSelectedBg      string
	cachedVDivider        string
	cachedFocusedVDivider string
)

func profileStyles() (bgSeq, vDivider, focusedVDivider string) {
	p := lipgloss.ColorProfile()
	styleCacheMu.Lock()
	defer styleCacheMu.Unlock()
	if !styleCacheInit || p != styleCacheProfile {
		marker := rowSelectedStyle.Render("x")
		cachedSelectedBg = ""
		if idx := strings.Index(marker, "x"); idx >= 0 {
			cachedSelectedBg = marker[:idx]
		}
		cachedVDivider = vDividerStyle.Render("│")
		cachedFocusedVDivider = detailFocusDividerStyle.Render("┃")
		styleCacheProfile = p
		styleCacheInit = true
	}
	return cachedSelectedBg, cachedVDivider, cachedFocusedVDivider
}

func verticalDividerCell(focused bool) string {
	_, cell, focusedCell := profileStyles()
	if focused {
		return focusedCell
	}
	return cell
}

func applySelectedBackground(s string) string {
	bgSeq, _, _ := profileStyles()
	if bgSeq == "" {
		return s
	}
	var b strings.Builder
	b.Grow(len(s) + len(bgSeq)*2 + 8)
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
