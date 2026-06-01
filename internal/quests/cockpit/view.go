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
	titleStyle    = lipgloss.NewStyle().Foreground(palette.Accent).Bold(true)
	mutedStyle    = lipgloss.NewStyle().Foreground(palette.Muted)
	selStyle      = lipgloss.NewStyle().Foreground(palette.BrightText).Bold(true)
	okStyle       = lipgloss.NewStyle().Foreground(palette.Clean)
	warnStyle     = lipgloss.NewStyle().Foreground(palette.Warn)
	errStyle      = lipgloss.NewStyle().Foreground(palette.Error)
	keyStyle      = lipgloss.NewStyle().Foreground(palette.Accent).Bold(true)
	keyLabelStyle = lipgloss.NewStyle().Foreground(palette.Muted)
)

// View renders the three-pane cockpit.
func (m Model) View() string {
	if m.quitting {
		return ""
	}
	if m.width < minWidth || m.height < minHeight {
		return "cockpit: terminal too small\n"
	}

	bodyH := m.height - 1 // reserve the footer row
	rosterW := pct(m.width, 26)
	questsW := pct(m.width, 30)
	detailW := m.width - rosterW - questsW - 6 // 3 boxes × 2 border cols
	if detailW < 16 {
		detailW = 16
	}

	roster := m.renderColumn("agents", m.rosterLines(rosterW), rosterW, bodyH-2, m.focus == paneRoster)
	quests := m.renderColumn("quests", m.questLines(questsW), questsW, bodyH-2, m.focus == paneQuests)
	detail := m.renderColumn("detail", m.detailLines(detailW), detailW, bodyH-2, m.focus == paneDetail)

	cols := lipgloss.JoinHorizontal(lipgloss.Top, roster, quests, detail)
	return cols + "\n" + m.footer(m.width)
}

func (m Model) renderColumn(title string, lines []string, width, height int, active bool) string {
	border := palette.DividerBorder
	if active {
		border = palette.Accent
	}
	head := titleStyle.Render(title)
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
	if len(m.sessions) == 0 {
		return []string{mutedStyle.Render("no sessions")}
	}
	lines := make([]string, 0, len(m.sessions))
	for i, s := range m.sessions {
		marker := "  "
		if i == m.rosterSel {
			marker = selStyle.Render("▸ ")
		}
		repo := s.Repo
		if repo == "" {
			repo = "—"
		}
		label := fmt.Sprintf("%s %s", agentGlyph(s.Agent), s.ID)
		sub := mutedStyle.Render(fmt.Sprintf("%s · %s · %s", repo, orDash(s.Role), orDash(s.State)))
		lines = append(lines, marker+ansiTrunc(label, inner-2))
		lines = append(lines, "   "+ansiTrunc(sub, inner-3))
	}
	return lines
}

func (m Model) questLines(width int) []string {
	inner := width - 2
	if len(m.quests) == 0 {
		return []string{mutedStyle.Render("no quests yet"), "", mutedStyle.Render("create one: quest new <id>")}
	}
	lines := make([]string, 0, len(m.quests))
	for i, q := range m.quests {
		marker := "  "
		if i == m.questSel {
			marker = selStyle.Render("▸ ")
		}
		lines = append(lines, marker+ansiTrunc(selOrPlain(i == m.questSel, q.ID), inner-2))
		lines = append(lines, "   "+ansiTrunc(mutedStyle.Render(q.Goal), inner-3))
	}
	return lines
}

func (m Model) detailLines(width int) []string {
	inner := width - 2
	q, ok := m.selectedQuest()
	if !ok {
		return []string{mutedStyle.Render("select a quest")}
	}
	var lines []string
	add := func(s string) { lines = append(lines, ansiTrunc(s, inner)) }

	add(titleStyle.Render(q.ID))
	add(q.Goal)
	add("")

	status := runtime.StatusDraft
	if m.detail != nil {
		status = m.detail.Status
	}
	add(mutedStyle.Render("status  ") + string(status))
	if q.Worktree != "" {
		add(mutedStyle.Render("worktree ") + q.Worktree)
	}
	if len(q.Context) > 0 {
		add(mutedStyle.Render("context ") + strings.Join(q.Context, " "))
	}

	if len(q.Gates) > 0 {
		add("")
		add(mutedStyle.Render("gates"))
		for _, g := range q.Gates {
			result := "unset"
			if m.detail != nil {
				if r, ok := m.detail.GateResults[g.Name]; ok && r != "" {
					result = r
				}
			}
			tag := fmt.Sprintf("[%s]", g.Type)
			before := ""
			if g.Before != "" {
				before = " before:" + g.Before
			}
			add(fmt.Sprintf("  %s %s%s — %s", tag, g.Name, before, gateResultStyle(result)))
		}
	}

	if len(q.Next) > 0 {
		add("")
		add(mutedStyle.Render("next"))
		for _, n := range q.Next {
			add("  ○ " + n)
		}
	}

	if m.detail != nil && len(m.detail.Sessions) > 0 {
		add("")
		add(mutedStyle.Render("sessions"))
		for _, s := range m.detail.Sessions {
			add(fmt.Sprintf("  %s %s/%s %s", s.ID, s.Role, s.Agent, s.State))
		}
	}

	add("")
	if m.detail != nil && m.detail.PR != nil {
		pr := m.detail.PR
		add(mutedStyle.Render("PR ") + fmt.Sprintf("#%d  ci:%s  review:%s", pr.Number, pr.CI, pr.Review))
	} else {
		add(mutedStyle.Render("PR ") + "no PR")
	}

	// scroll
	if m.detailScroll > 0 && m.detailScroll < len(lines) {
		lines = lines[m.detailScroll:]
	}
	return lines
}

func (m Model) footer(width int) string {
	if m.err != nil {
		return errStyle.Render(ansiTrunc("error: "+m.err.Error(), width))
	}
	hints := []struct{ k, l string }{
		{"tab", "focus"},
		{"↑↓", "move"},
		{"o", "open"},
		{"d", "diff"},
		{"r", "refresh"},
		{"q", "quit"},
	}
	var b strings.Builder
	for i, h := range hints {
		if i > 0 {
			b.WriteString("  ")
		}
		b.WriteString(keyStyle.Render(h.k) + " " + keyLabelStyle.Render(h.l))
	}
	line := b.String()
	if m.status != "" {
		line = okStyle.Render(m.status) + "   " + line
	}
	return ansiTrunc(line, width)
}

// --- small helpers ---

func pct(total, p int) int {
	w := total * p / 100
	if w < 14 {
		w = 14
	}
	return w
}

func ansiTrunc(s string, max int) string {
	if max <= 0 {
		return ""
	}
	return ansi.Truncate(s, max, "…")
}

func orDash(s string) string {
	if s == "" {
		return "—"
	}
	return s
}

func selOrPlain(sel bool, s string) string {
	if sel {
		return selStyle.Render(s)
	}
	return s
}

func agentGlyph(agent string) string {
	switch agent {
	case "claude":
		return lipgloss.NewStyle().Foreground(palette.ClaudeColor).Render("●")
	case "codex":
		return lipgloss.NewStyle().Foreground(palette.CodexColor).Render("●")
	case "pi":
		return lipgloss.NewStyle().Foreground(palette.PiColor).Render("●")
	default:
		return mutedStyle.Render("●")
	}
}

func gateResultStyle(result string) string {
	switch result {
	case "green":
		return okStyle.Render(result)
	case "failed":
		return errStyle.Render(result)
	case "pending":
		return warnStyle.Render(result)
	default:
		return mutedStyle.Render(result)
	}
}
