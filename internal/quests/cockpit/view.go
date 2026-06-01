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
	paneTitleStyle   = lipgloss.NewStyle().Foreground(palette.Accent).Bold(true)
	paneTitleActive  = lipgloss.NewStyle().Foreground(palette.Warn).Bold(true)
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

// View renders the Quests dashboard with the tracker's borderless chrome
// (title + dim rule + body, no box) and background-fill selection.
func (m Model) View() string {
	if m.quitting {
		return ""
	}
	if m.width < minWidth || m.height < minHeight {
		return "quests: terminal too small\n"
	}

	paneH := m.height - 1 // reserve the footer row

	var cols string
	if m.detailOpen {
		listW := pct(m.width, 40)
		detailW := m.width - listW - 3
		if detailW < 20 {
			detailW = 20
		}
		list := m.renderPane("quests", listTag(m.rows), m.questLines(listW), listW, paneH, m.focus == paneQuests)
		detail := m.renderPane(m.detailTitle(), "", m.detailLines(detailW), detailW, paneH, m.focus == paneDetail)
		cols = lipgloss.JoinHorizontal(lipgloss.Top, list, paneDivider(paneH), detail)
	} else {
		cols = m.renderPane("quests", listTag(m.rows), m.questLines(m.width), m.width, paneH, true)
	}
	return cols + "\n" + m.footer(m.width)
}

func listTag(rows []QuestRow) string {
	if len(rows) == 0 {
		return ""
	}
	return fmt.Sprintf("%d", len(rows))
}

func (m Model) detailTitle() string {
	if id, ok := m.selectedQuestID(); ok {
		return id
	}
	return "details"
}

// renderPane draws a borderless pane: a title line, a dim full-width rule, then
// body lines, padded to width and height.
func (m Model) renderPane(title, tag string, lines []string, width, height int, active bool) string {
	ts := paneTitleStyle
	if active {
		ts = paneTitleActive
	}
	head := ts.Render(title)
	if tag != "" {
		head += " " + dimStyle.Render(tag)
	}

	out := make([]string, 0, height)
	out = append(out, padTo(head, width))
	out = append(out, dividerStyle.Render(strings.Repeat("─", width)))
	for _, ln := range lines {
		if len(out) >= height {
			break
		}
		out = append(out, padTo(ln, width))
	}
	for len(out) < height {
		out = append(out, strings.Repeat(" ", width))
	}
	return strings.Join(out, "\n")
}

// paneDivider is the dim vertical rule between the list and detail panes.
func paneDivider(height int) string {
	line := dividerStyle.Render(" │ ")
	rows := make([]string, height)
	for i := range rows {
		rows[i] = line
	}
	return strings.Join(rows, "\n")
}

func (m Model) questLines(width int) []string {
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
		glyph := statusGlyph(rowStatus(row))
		chips := gateChips(row)

		if selected {
			// Selection = a full-width background fill (matches the tracker).
			// Plain text under the fill so the highlight is continuous.
			head := "  " + glyphPlain(rowStatus(row)) + " " + row.Quest.ID
			if pc := chipsPlain(row); pc != "" {
				head += "  " + pc
			}
			lines = append(lines, selectedRowStyle.Width(width).Render(ansiTrunc(head, width)))
			lines = append(lines, selectedRowStyle.Width(width).Render(ansiTrunc("    "+row.Quest.Goal, width)))
			continue
		}
		head := "  " + glyph + " " + idStyle.Render(row.Quest.ID)
		if chips != "" {
			head += "  " + chips
		}
		lines = append(lines, head)
		lines = append(lines, "    "+mutedStyle.Render(row.Quest.Goal))
	}
	return lines
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

func (m Model) detailLines(width int) []string {
	row, ok := m.selectedRow()
	if !ok {
		return []string{mutedStyle.Render("select a quest · ⏎")}
	}
	q := row.Quest
	rec := row.Runtime
	var lines []string
	add := func(s string) { lines = append(lines, s) }
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
		add("")
		add(sectionStyle.Render("next"))
		for _, n := range q.Next {
			add(mutedStyle.Render("  ○ ") + n)
		}
	}

	if rec != nil && len(rec.Sessions) > 0 {
		add("")
		add(sectionStyle.Render("sessions"))
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

// padTo truncates (ANSI-aware) then pads s to exactly width cells.
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
