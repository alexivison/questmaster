package cockpit

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"

	"github.com/alexivison/questmaster/internal/palette"
	"github.com/alexivison/questmaster/internal/quests/quest"
	"github.com/alexivison/questmaster/internal/quests/runtime"
)

const (
	minWidth  = 50
	minHeight = 8
)

var (
	titleStyle  = lipgloss.NewStyle().Foreground(palette.Accent).Bold(true)
	cyanTitle   = lipgloss.NewStyle().Foreground(palette.HunkHeader).Bold(true)
	mutedStyle  = lipgloss.NewStyle().Foreground(palette.Muted)
	repoStyle   = lipgloss.NewStyle().Foreground(palette.Muted).Bold(true)
	selStyle    = lipgloss.NewStyle().Foreground(palette.Warn).Bold(true)
	brightStyle = lipgloss.NewStyle().Foreground(palette.BrightText).Bold(true)
	okStyle     = lipgloss.NewStyle().Foreground(palette.Clean)
	warnStyle   = lipgloss.NewStyle().Foreground(palette.Warn)
	errStyle    = lipgloss.NewStyle().Foreground(palette.Error)
	keyStyle    = lipgloss.NewStyle().Foreground(palette.Warn).Bold(true)
	keyLabel    = lipgloss.NewStyle().Foreground(palette.Muted)
	dimStyle    = lipgloss.NewStyle().Foreground(palette.Muted)
)

// View renders the cockpit. The detail pane is hidden until opened (scan mode);
// the left agents roster is always the smallest pane.
func (m Model) View() string {
	if m.quitting {
		return ""
	}
	if m.width < minWidth || m.height < minHeight {
		return "cockpit: terminal too small\n"
	}

	bodyH := m.height - 1 // footer row
	leftW := pct(m.width, 22)

	var cols string
	if m.detailOpen {
		detailW := pct(m.width, 36)
		midW := m.width - leftW - detailW - 6
		if midW < 18 {
			midW = 18
		}
		roster := m.renderColumn("agents", "live", m.rosterLines(leftW), leftW, bodyH-2, m.focus == paneRoster)
		quests := m.renderColumn("quests", questsTag(m.quests), m.questLines(midW), midW, bodyH-2, m.focus == paneQuests)
		detail := m.renderColumn(m.detailTitle(), "▸ esc", m.detailLines(detailW), detailW, bodyH-2, m.focus == paneDetail)
		cols = lipgloss.JoinHorizontal(lipgloss.Top, roster, quests, detail)
	} else {
		midW := m.width - leftW - 4
		if midW < 18 {
			midW = 18
		}
		roster := m.renderColumn("agents", "live", m.rosterLines(leftW), leftW, bodyH-2, m.focus == paneRoster)
		quests := m.renderColumn("quests", questsTag(m.quests), m.questLines(midW), midW, bodyH-2, m.focus == paneQuests)
		cols = lipgloss.JoinHorizontal(lipgloss.Top, roster, quests)
	}

	return cols + "\n" + m.footer(m.width)
}

func (m Model) detailTitle() string {
	if id, ok := m.selectedQuestID(); ok {
		return id + " · details"
	}
	return "details"
}

func questsTag(quests []quest.Quest) string {
	if len(quests) == 0 {
		return ""
	}
	return fmt.Sprintf("%d", len(quests))
}

func (m Model) renderColumn(title, tag string, lines []string, width, height int, active bool) string {
	border := palette.DividerBorder
	if active {
		border = palette.Warn
	}
	head := titleStyle.Render(title)
	if title == "agents" || title == "quests" {
		head = titleStyle.Render(title)
	} else {
		head = cyanTitle.Render(title)
	}
	if tag != "" {
		head += "  " + dimStyle.Render(tag)
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

func (m Model) rosterLines(width int) []string {
	inner := width - 2
	if m.selectableCount() == 0 {
		return []string{mutedStyle.Render("no sessions")}
	}
	var lines []string
	sel := 0
	for _, it := range m.items {
		if it.header {
			lines = append(lines, repoStyle.Render(ansiTrunc(strings.ToLower(it.repo), inner)))
			continue
		}
		selected := sel == m.rosterSel
		lines = append(lines, m.rosterRow(it.sess, selected, inner))
		sel++
	}
	return lines
}

func (m Model) rosterRow(s SessionRow, selected bool, inner int) string {
	marker := "  "
	if selected {
		marker = selStyle.Render("▸ ")
	}
	glyph := stateGlyph(s.State)

	label := s.Title
	if label == "" {
		label = s.ID
	}
	indent := ""
	if s.Depth > 0 {
		indent = "  "
		label = "└ " + label
	}
	labelStyle := lipgloss.NewStyle()
	if selected {
		labelStyle = brightStyle
	}

	line := marker + indent + glyph + " " + labelStyle.Render(label)
	if s.Role != "" && s.Depth == 0 {
		line += " " + mutedStyle.Render(s.Role)
	}
	if s.Activity != "" {
		line += " " + dimStyle.Render(s.Activity)
	}
	return ansiTrunc(line, inner)
}

func (m Model) questLines(width int) []string {
	inner := width - 2
	if len(m.quests) == 0 {
		return []string{
			mutedStyle.Render("no quests yet"),
			"",
			dimStyle.Render("press a to author one"),
		}
	}
	var lines []string
	for i, q := range m.quests {
		selected := i == m.questSel
		marker := "  "
		if selected {
			marker = selStyle.Render("▸ ")
		}
		name := q.ID
		if selected {
			name = brightStyle.Render(q.ID)
		} else {
			name = lipgloss.NewStyle().Bold(true).Render(q.ID)
		}
		lines = append(lines, ansiTrunc(marker+name, inner))
		lines = append(lines, ansiTrunc("    "+mutedStyle.Render(q.Goal), inner))
	}
	return lines
}

func (m Model) detailLines(width int) []string {
	inner := width - 2
	q, ok := m.selectedQuest()
	if !ok {
		return []string{mutedStyle.Render("select a quest · ⏎")}
	}
	var lines []string
	add := func(s string) { lines = append(lines, ansiTrunc(s, inner)) }

	add(q.Goal)
	status := runtime.StatusDraft
	if m.detail != nil {
		status = m.detail.Status
	}
	add(mutedStyle.Render("status ") + string(status))
	if q.Worktree != "" {
		add(mutedStyle.Render("tree   ") + okStyle.Render(q.Worktree))
	}
	if len(q.Context) > 0 {
		add(mutedStyle.Render("ctx    ") + strings.Join(q.Context, " "))
	}

	if len(q.Gates) > 0 {
		add("")
		add(cyanTitle.Render("gates") + dimStyle.Render(" · from quest file"))
		for _, g := range q.Gates {
			result := "unset"
			if m.detail != nil {
				if r, ok := m.detail.GateResults[g.Name]; ok && r != "" {
					result = r
				}
			}
			before := ""
			if g.Before != "" {
				before = " " + dimStyle.Render("before:"+g.Before)
			}
			add(fmt.Sprintf("%s %s %s%s", gateMark(result), g.Name, gateType(string(g.Type)), before))
		}
	}

	if len(q.Next) > 0 {
		add("")
		add(cyanTitle.Render("next"))
		for _, n := range q.Next {
			add(mutedStyle.Render("  ○ ") + n)
		}
	}

	if m.detail != nil && len(m.detail.Sessions) > 0 {
		add("")
		add(cyanTitle.Render("sessions"))
		for _, s := range m.detail.Sessions {
			add(fmt.Sprintf("  %s %s/%s %s", stateGlyph(s.State), s.Role, s.Agent, s.State))
		}
	}

	add("")
	if m.detail != nil && m.detail.PR != nil {
		pr := m.detail.PR
		add(mutedStyle.Render("PR ") + fmt.Sprintf("#%d  %s  %s", pr.Number, ciMark(pr.CI), reviewMark(pr.Review)))
	} else {
		add(mutedStyle.Render("PR ") + dimStyle.Render("none"))
	}

	add("")
	add(dimStyle.Render("steer · stage 2"))

	if m.detailScroll > 0 && m.detailScroll < len(lines) {
		lines = lines[m.detailScroll:]
	}
	return lines
}

func (m Model) footer(width int) string {
	if m.authoring {
		return ansiTrunc(m.input.View(), width)
	}
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
			{"↑↓", "move"}, {"⇥", "pane"}, {"⏎", "open"}, {"a", "author"}, {"n", "new"}, {"g", "go"}, {"r", "refresh"}, {"q", "quit"},
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

// --- glyph / mark helpers (match the cockpit-layout mock vocabulary) ---

func stateGlyph(state string) string {
	switch state {
	case "working", "starting", "busy":
		return warnStyle.Render("◐")
	case "done", "idle_done":
		return okStyle.Render("●")
	case "blocked", "error", "failed", "stuck":
		return errStyle.Render("!")
	default: // idle, queued, unknown, ""
		return dimStyle.Render("○")
	}
}

func gateMark(result string) string {
	switch result {
	case "green":
		return okStyle.Render("✓")
	case "failed":
		return errStyle.Render("✗")
	case "pending":
		return warnStyle.Render("◐")
	default:
		return dimStyle.Render("·")
	}
}

func gateType(t string) string {
	switch t {
	case "auto":
		return okStyle.Render("auto")
	case "toggle":
		return cyanTitle.Render("toggle")
	default:
		return dimStyle.Render(t)
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
		return okStyle.Render("PR✓")
	case "changes":
		return errStyle.Render("PR✗")
	case "pending":
		return warnStyle.Render("PR◐")
	default:
		return dimStyle.Render("PR·")
	}
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
