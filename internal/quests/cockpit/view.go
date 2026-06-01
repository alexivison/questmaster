package cockpit

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"

	"github.com/alexivison/questmaster/internal/palette"
	"github.com/alexivison/questmaster/internal/quests/runtime"
)

const (
	minWidth  = 40
	minHeight = 8
)

var (
	appTitle    = lipgloss.NewStyle().Foreground(palette.Warn).Bold(true)
	titleStyle  = lipgloss.NewStyle().Foreground(palette.Accent).Bold(true)
	cyanTitle   = lipgloss.NewStyle().Foreground(palette.HunkHeader).Bold(true)
	mutedStyle  = lipgloss.NewStyle().Foreground(palette.Muted)
	selStyle    = lipgloss.NewStyle().Foreground(palette.Warn).Bold(true)
	brightStyle = lipgloss.NewStyle().Foreground(palette.BrightText).Bold(true)
	okStyle     = lipgloss.NewStyle().Foreground(palette.Clean)
	warnStyle   = lipgloss.NewStyle().Foreground(palette.Warn)
	errStyle    = lipgloss.NewStyle().Foreground(palette.Error)
	keyStyle    = lipgloss.NewStyle().Foreground(palette.Warn).Bold(true)
	keyLabel    = lipgloss.NewStyle().Foreground(palette.Muted)
	dimStyle    = lipgloss.NewStyle().Foreground(palette.Muted)
)

// View renders the Quests dashboard: a title bar, the quests list, and a
// toggleable detail pane.
func (m Model) View() string {
	if m.quitting {
		return ""
	}
	if m.width < minWidth || m.height < minHeight {
		return "quests: terminal too small\n"
	}

	header := m.header(m.width)
	bodyH := m.height - 3 // header + footer + spacing

	var cols string
	if m.detailOpen {
		listW := pct(m.width, 40)
		detailW := m.width - listW - 4
		if detailW < 20 {
			detailW = 20
		}
		list := m.renderColumn("quests", m.questLines(listW), listW, bodyH, m.focus == paneQuests)
		detail := m.renderColumn(m.detailTitle(), m.detailLines(detailW), detailW, bodyH, m.focus == paneDetail)
		cols = lipgloss.JoinHorizontal(lipgloss.Top, list, detail)
	} else {
		cols = m.renderColumn("quests", m.questLines(m.width-2), m.width-2, bodyH, true)
	}
	return header + "\n" + cols + "\n" + m.footer(m.width)
}

// header is the app title bar.
func (m Model) header(width int) string {
	left := appTitle.Render("✦ quests") + "  " + dimStyle.Render(fmt.Sprintf("%d", len(m.rows)))
	return ansiTrunc(left, width)
}

func (m Model) detailTitle() string {
	if id, ok := m.selectedQuestID(); ok {
		return id
	}
	return "details"
}

func (m Model) renderColumn(title string, lines []string, width, height int, active bool) string {
	border := palette.DividerBorder
	if active {
		border = palette.Warn
	}
	head := titleStyle.Render(title)
	if title != "quests" {
		head = cyanTitle.Render(title) + dimStyle.Render(" · details")
	}
	body := head + "\n" + strings.Join(lines, "\n")
	return lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(border).
		Width(width).
		Height(height).
		Padding(0, 1).
		Render(body)
}

func (m Model) questLines(width int) []string {
	inner := width - 2
	if len(m.rows) == 0 {
		return []string{
			mutedStyle.Render("no quests yet"),
			"",
			dimStyle.Render("ask a session to create one,"),
			dimStyle.Render("or: quests quest new <id>"),
		}
	}
	var lines []string
	for i, row := range m.rows {
		selected := i == m.questSel
		marker := "  "
		if selected {
			marker = selStyle.Render("▸ ")
		}
		glyph := statusGlyph(rowStatus(row))
		id := lipgloss.NewStyle().Bold(true).Render(row.Quest.ID)
		if selected {
			id = brightStyle.Render(row.Quest.ID)
		}
		chips := gateChips(row)
		head := marker + glyph + " " + id
		if chips != "" {
			head += "  " + chips
		}
		lines = append(lines, ansiTrunc(head, inner))
		lines = append(lines, ansiTrunc("    "+mutedStyle.Render(row.Quest.Goal), inner))
	}
	return lines
}

// gateChips renders compact per-gate result glyphs + a PR marker for a row.
func gateChips(row QuestRow) string {
	var parts []string
	for _, g := range row.Quest.Gates {
		result := ""
		if row.Runtime != nil {
			result = row.Runtime.GateResults[g.Name]
		}
		glyph, style := gateGlyph(string(g.Type), result)
		parts = append(parts, style.Render(glyph+g.Name))
	}
	if row.Runtime != nil && row.Runtime.PR != nil {
		parts = append(parts, prChip(row.Runtime.PR))
	}
	return strings.Join(parts, " ")
}

func (m Model) detailLines(width int) []string {
	inner := width - 2
	row, ok := m.selectedRow()
	if !ok {
		return []string{mutedStyle.Render("select a quest · ⏎")}
	}
	q := row.Quest
	rec := row.Runtime
	var lines []string
	add := func(s string) { lines = append(lines, ansiTrunc(s, inner)) }
	label := func(k, v string) { add(dimStyle.Render(rightPad(k, 8)) + v) }

	add(q.Goal)
	add("")
	label("status", statusGlyph(rowStatus(row))+" "+string(rowStatus(row)))
	if q.Worktree != "" {
		label("tree", okStyle.Render(q.Worktree))
	}
	if len(q.Context) > 0 {
		label("context", strings.Join(q.Context, "  "))
	}

	if len(q.Gates) > 0 {
		add("")
		add(cyanTitle.Render("gates") + dimStyle.Render(" · from quest file"))
		for _, g := range q.Gates {
			result := "unset"
			if rec != nil {
				if r, ok := rec.GateResults[g.Name]; ok && r != "" {
					result = r
				}
			}
			glyph, style := gateGlyph(string(g.Type), gateResultKey(rec, g.Name))
			before := ""
			if g.Before != "" {
				before = " " + dimStyle.Render("before:"+g.Before)
			}
			add("  " + style.Render(glyph) + " " + g.Name + " " + gateTypeLabel(string(g.Type)) + before + dimStyle.Render("  "+result))
		}
	}

	if len(q.Next) > 0 {
		add("")
		add(cyanTitle.Render("next"))
		for _, n := range q.Next {
			add(mutedStyle.Render("  ○ ") + n)
		}
	}

	if rec != nil && len(rec.Sessions) > 0 {
		add("")
		add(cyanTitle.Render("sessions"))
		for _, s := range rec.Sessions {
			add("  " + sessionStateGlyph(s.State) + " " + s.Agent + dimStyle.Render(" "+s.Role+" "+s.State))
		}
	}

	add("")
	if rec != nil && rec.PR != nil {
		add(dimStyle.Render(rightPad("PR", 8)) + fmt.Sprintf("#%d  %s  %s", rec.PR.Number, ciMark(rec.PR.CI), reviewMark(rec.PR.Review)))
	} else {
		add(dimStyle.Render(rightPad("PR", 8)) + dimStyle.Render("none yet"))
	}

	if m.detailScroll > 0 && m.detailScroll < len(lines) {
		lines = lines[m.detailScroll:]
	}
	return lines
}

func (m Model) footer(width int) string {
	if m.err != nil {
		return errStyle.Render(ansiTrunc("error: "+m.err.Error(), width))
	}
	var hints []struct{ k, l string }
	if m.detailOpen {
		hints = []struct{ k, l string }{
			{"↑↓", "scroll"}, {"⇥", "pane"}, {"o", "open"}, {"d", "diff"}, {"e", "edit"}, {"esc", "close"}, {"q", "quit"},
		}
	} else {
		hints = []struct{ k, l string }{
			{"↑↓", "move"}, {"⏎", "details"}, {"o", "open"}, {"d", "diff"}, {"e", "edit"}, {"r", "refresh"}, {"q", "quit"},
		}
	}
	var b strings.Builder
	for i, h := range hints {
		if i > 0 {
			b.WriteString("  ")
		}
		b.WriteString(keyStyle.Render(h.k) + " " + keyLabel.Render(h.l))
	}
	line := b.String()
	if m.status != "" {
		line = okStyle.Render(m.status) + "   " + line
	}
	return ansiTrunc(line, width)
}

// --- status / glyph helpers ---

func rowStatus(row QuestRow) runtime.Status {
	if row.Runtime != nil && row.Runtime.Status != "" {
		return row.Runtime.Status
	}
	return runtime.StatusDraft
}

func statusGlyph(s runtime.Status) string {
	switch s {
	case runtime.StatusInProgress:
		return warnStyle.Render("◐")
	case runtime.StatusDone:
		return okStyle.Render("●")
	case runtime.StatusBlocked:
		return errStyle.Render("!")
	case runtime.StatusReady:
		return cyanTitle.Render("○")
	default: // draft
		return dimStyle.Render("○")
	}
}

func gateResultKey(rec *runtime.RuntimeRecord, name string) string {
	if rec == nil {
		return ""
	}
	return rec.GateResults[name]
}

// gateGlyph maps a gate type + result to a glyph and style.
func gateGlyph(gtype, result string) (string, lipgloss.Style) {
	switch result {
	case "green":
		return "✓", okStyle
	case "failed":
		return "✗", errStyle
	case "pending":
		return "◐", warnStyle
	}
	if gtype == "toggle" {
		return "☐", cyanTitle
	}
	return "·", dimStyle
}

func gateTypeLabel(t string) string {
	switch t {
	case "auto":
		return okStyle.Render("auto")
	case "toggle":
		return cyanTitle.Render("toggle")
	default:
		return dimStyle.Render(t)
	}
}

func prChip(pr *runtime.PRStatus) string {
	style := dimStyle
	switch pr.CI {
	case "green":
		style = okStyle
	case "failed":
		style = errStyle
	case "pending":
		style = warnStyle
	}
	return style.Render(fmt.Sprintf("#%d", pr.Number))
}

func sessionStateGlyph(stateStr string) string {
	switch stateStr {
	case "working", "starting", "busy":
		return warnStyle.Render("◐")
	case "done":
		return okStyle.Render("●")
	case "blocked", "error", "stuck":
		return errStyle.Render("!")
	default:
		return dimStyle.Render("○")
	}
}

func ciMark(ci string) string {
	switch ci {
	case "green":
		return okStyle.Render("CI✓")
	case "failed":
		return errStyle.Render("CI✗")
	case "pending":
		return warnStyle.Render("CI◐")
	default:
		return dimStyle.Render("CI·")
	}
}

func reviewMark(r string) string {
	switch r {
	case "approved":
		return okStyle.Render("review✓")
	case "changes":
		return errStyle.Render("review✗")
	case "pending":
		return warnStyle.Render("review◐")
	default:
		return dimStyle.Render("review·")
	}
}

func rightPad(s string, n int) string {
	if len(s) >= n {
		return s
	}
	return s + strings.Repeat(" ", n-len(s))
}

func pct(total, p int) int {
	w := total * p / 100
	if w < 16 {
		w = 16
	}
	return w
}

func ansiTrunc(s string, max int) string {
	if max <= 0 {
		return ""
	}
	return ansi.Truncate(s, max, "…")
}
