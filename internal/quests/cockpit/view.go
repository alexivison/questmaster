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
	paneTitleStyle   = lipgloss.NewStyle().Foreground(palette.Warn).Bold(true)
	sectionStyle     = lipgloss.NewStyle().Foreground(palette.HunkHeader).Bold(true)
	mutedStyle       = lipgloss.NewStyle().Foreground(palette.Muted)
	dimStyle         = lipgloss.NewStyle().Foreground(palette.Muted)
	dividerStyle     = lipgloss.NewStyle().Foreground(palette.DividerFg)
	okStyle          = lipgloss.NewStyle().Foreground(palette.Clean)
	warnStyle        = lipgloss.NewStyle().Foreground(palette.Warn)
	errStyle         = lipgloss.NewStyle().Foreground(palette.Error)
	keyStyle         = lipgloss.NewStyle().Foreground(palette.Warn).Bold(true)
	keyLabel         = lipgloss.NewStyle().Foreground(palette.Muted)
	idStyle          = lipgloss.NewStyle().Foreground(palette.BrightText).Bold(true)
	selectedRowStyle = lipgloss.NewStyle().Background(palette.SelectedRowBg).Foreground(palette.BrightText)
)

// View renders the Quests dashboard: a single borderless quests list (title +
// dim rule + body), where the selected quest expands inline to its detail. The
// list auto-scrolls to keep the selected quest visible.
func (m Model) View() string {
	if m.quitting {
		return ""
	}
	if m.width < minWidth || m.height < minHeight {
		return "quests: terminal too small\n"
	}

	width := m.width
	title := paneTitleStyle.Render("quests")
	if n := len(m.rows); n > 0 {
		title += " " + dimStyle.Render(fmt.Sprintf("%d", n))
	}

	avail := m.height - 3 // title + rule + footer
	if avail < 1 {
		avail = 1
	}
	body := m.bodyLines(width, avail)

	out := make([]string, 0, m.height)
	out = append(out, padTo(title, width))
	out = append(out, dividerStyle.Render(strings.Repeat("─", width)))
	for _, ln := range body {
		out = append(out, padTo(ln, width))
	}
	for len(out) < m.height-1 {
		out = append(out, strings.Repeat(" ", width))
	}
	return strings.Join(out, "\n") + "\n" + m.footer(width)
}

// bodyLines builds the accordion (collapsed rows + the selected quest expanded)
// and scrolls it so the selected quest's block stays within avail lines.
func (m Model) bodyLines(width, avail int) []string {
	if len(m.rows) == 0 {
		return []string{
			mutedStyle.Render("no quests yet"),
			"",
			dimStyle.Render("ask a session to create one,"),
			dimStyle.Render("or: quests quest new <id>"),
		}
	}

	var all []string
	selStart, selEnd := 0, 0
	for i, row := range m.rows {
		if i > 0 {
			all = append(all, "")
		}
		start := len(all)
		all = append(all, m.collapsedLine(row, i == m.questSel, width))
		if i == m.questSel {
			for _, dl := range m.detailLines(row) {
				all = append(all, "  "+dl)
			}
		}
		if i == m.questSel {
			selStart, selEnd = start, len(all)-1
		}
	}

	if len(all) <= avail {
		return all
	}
	// Scroll so the selected block is visible (prefer its top).
	scroll := 0
	if selEnd >= avail {
		scroll = selEnd - avail + 1
	}
	if scroll > selStart {
		scroll = selStart
	}
	end := scroll + avail
	if end > len(all) {
		end = len(all)
	}
	return all[scroll:end]
}

// collapsedLine is the one-line summary for a quest: status glyph · id · gate
// chips · PR · goal. The selected quest's summary gets a background fill.
func (m Model) collapsedLine(row QuestRow, selected bool, width int) string {
	if selected {
		head := "  " + glyphPlain(rowStatus(row)) + " " + row.Quest.ID
		if pc := chipsPlain(row); pc != "" {
			head += "  " + pc
		}
		head += "   " + row.Quest.Goal
		return selectedRowStyle.Width(width).Render(ansiTrunc(head, width))
	}
	head := "  " + statusGlyph(rowStatus(row)) + " " + idStyle.Render(row.Quest.ID)
	if chips := gateChips(row); chips != "" {
		head += "  " + chips
	}
	head += "   " + mutedStyle.Render(row.Quest.Goal)
	return head
}

func gateChips(row QuestRow) string {
	var parts []string
	for _, g := range row.Quest.Gates {
		glyph, style := gateGlyph(string(g.Type), gateResultKey(row.Runtime, g.Name))
		parts = append(parts, style.Render(glyph+g.Name))
	}
	if row.Runtime != nil && row.Runtime.PR != nil {
		parts = append(parts, prChip(row.Runtime.PR))
	}
	return strings.Join(parts, " ")
}

func chipsPlain(row QuestRow) string {
	var parts []string
	for _, g := range row.Quest.Gates {
		glyph, _ := gateGlyph(string(g.Type), gateResultKey(row.Runtime, g.Name))
		parts = append(parts, glyph+g.Name)
	}
	if row.Runtime != nil && row.Runtime.PR != nil {
		parts = append(parts, fmt.Sprintf("#%d", row.Runtime.PR.Number))
	}
	return strings.Join(parts, " ")
}

// detailLines is the expanded detail shown inline under the selected quest.
func (m Model) detailLines(row QuestRow) []string {
	q := row.Quest
	rec := row.Runtime
	var lines []string
	add := func(s string) { lines = append(lines, s) }
	label := func(k, v string) { add(dimStyle.Render(rightPad(k, 8)) + v) }

	label("status", string(rowStatus(row)))
	if q.Worktree != "" {
		label("tree", okStyle.Render(q.Worktree))
	}
	if len(q.Context) > 0 {
		label("context", strings.Join(q.Context, "  "))
	}

	if len(q.Gates) > 0 {
		add(sectionStyle.Render("gates") + dimStyle.Render(" · from quest file"))
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
		add(sectionStyle.Render("next"))
		for _, n := range q.Next {
			add(mutedStyle.Render("  ○ ") + n)
		}
	}

	if rec != nil && len(rec.Sessions) > 0 {
		add(sectionStyle.Render("sessions"))
		for _, s := range rec.Sessions {
			add("  " + sessionStateGlyph(s.State) + " " + s.Agent + dimStyle.Render(" "+s.Role+" "+s.State))
		}
	}

	if rec != nil && rec.PR != nil {
		label("PR", fmt.Sprintf("#%d  %s  %s", rec.PR.Number, ciMark(rec.PR.CI), reviewMark(rec.PR.Review)))
	}
	return lines
}

func (m Model) footer(width int) string {
	if m.err != nil {
		return errStyle.Render(ansiTrunc("error: "+m.err.Error(), width))
	}
	hints := []struct{ k, l string }{
		{"↑↓", "move"}, {"⏎", "open"}, {"d", "diff"}, {"e", "edit"}, {"r", "refresh"}, {"q", "quit"},
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

func glyphPlain(s runtime.Status) string {
	switch s {
	case runtime.StatusInProgress:
		return "◐"
	case runtime.StatusDone:
		return "●"
	case runtime.StatusBlocked:
		return "!"
	default:
		return "○"
	}
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
		return sectionStyle.Render("○")
	default:
		return dimStyle.Render("○")
	}
}

func gateResultKey(rec *runtime.RuntimeRecord, name string) string {
	if rec == nil {
		return ""
	}
	return rec.GateResults[name]
}

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
		return "☐", sectionStyle
	}
	return "·", dimStyle
}

func gateTypeLabel(t string) string {
	switch t {
	case "auto":
		return okStyle.Render("auto")
	case "toggle":
		return sectionStyle.Render("toggle")
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

func padTo(s string, width int) string {
	if width <= 0 {
		return ""
	}
	s = ansiTrunc(s, width)
	if gap := width - lipgloss.Width(s); gap > 0 {
		s += strings.Repeat(" ", gap)
	}
	return s
}

func ansiTrunc(s string, max int) string {
	if max <= 0 {
		return ""
	}
	return ansi.Truncate(s, max, "…")
}
