package quest

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

// Runtime is the derived, render-time state of a quest — which sessions are on
// it — gathered from the session scan and injected at render time. It is never
// stored on the quest itself (one fact, one home: the file holds authored
// content + status; attachment lives on session state).
type Runtime struct {
	// Sessions are the session IDs currently attached to (on) the quest.
	Sessions []string
}

// Attached reports whether any session is on the quest.
func (r Runtime) Attached() bool { return len(r.Sessions) > 0 }

// DetailTargetKind identifies an interactive row in the detail pane.
type DetailTargetKind int

const (
	// TargetGate is a toggle gate (the only flippable gate kind).
	TargetGate DetailTargetKind = iota
	// TargetRelated is a related entry (openable in T12).
	TargetRelated
)

// DetailTarget is one interactive row: a toggle gate or a related entry,
// addressed by its index into q.Gates / q.Related.
type DetailTarget struct {
	Kind  DetailTargetKind
	Index int
}

// DetailFocus describes which interactive row the detail pane has focused.
// Active is false for read-only renders (qm quest view); the board sets it
// when the pane has focus. Shared by the board (navigation) and the renderer
// (highlight) so they agree on what is selected.
type DetailFocus struct {
	Active bool
	Kind   DetailTargetKind
	Index  int
}

func (f DetailFocus) hits(kind DetailTargetKind, index int) bool {
	return f.Active && f.Kind == kind && f.Index == index
}

// DetailTargets enumerates the interactive rows in display order: toggle gates
// (in gate order) then related entries. Auto gates are not interactive — their
// state is observed, not authored — so they are skipped.
func DetailTargets(q *Quest) []DetailTarget {
	var t []DetailTarget
	for i, g := range q.Gates {
		if g.Type == GateToggle {
			t = append(t, DetailTarget{Kind: TargetGate, Index: i})
		}
	}
	for i := range q.Related {
		t = append(t, DetailTarget{Kind: TargetRelated, Index: i})
	}
	return t
}

// Glyphs shared by the three render levels and the HTML build's text fallbacks.
const (
	glyphFlag   = "⚑" // tracker / list: a quest is attached here
	glyphOnIt   = "⚔" // detail / list: sessions are on the quest
	glyphGate   = "◇" // gate diamond
	glyphSep    = "·" // id · goal separators
	glyphBullet = "·" // unordered list marker

	// Meta-line tag glyphs (nerd-font). Agent icons match the tracker exactly.
	glyphProject = ""          // folder — project
	glyphDate    = ""          // calendar — date
	glyphRelated = ""          // link — related tickets
	glyphAgent   = ""          // generic agent fallback
	iconClaude   = "\U000f06c4" // tracker per-agent glyphs
	iconCodex    = ""
	iconPi       = "π"
)

// agentGlyphPlain returns the per-agent glyph (matching the tracker), or a
// generic agent glyph for unknown agents.
func agentGlyphPlain(name string) string {
	switch name {
	case "claude":
		return iconClaude
	case "codex":
		return iconCodex
	case "pi":
		return iconPi
	default:
		return glyphAgent
	}
}

// agentGlyphStyled colours the per-agent glyph with the agent's brand hue, the
// same palette the tracker uses for its activity icon.
func agentGlyphStyled(name string) string {
	switch name {
	case "claude":
		return lipgloss.NewStyle().Foreground(lipgloss.Color("#CC785C")).Render(iconClaude)
	case "codex":
		return lipgloss.NewStyle().Foreground(lipgloss.Color("#1A73E8")).Render(iconCodex)
	case "pi":
		return lipgloss.NewStyle().Foreground(lipgloss.Color("#A371F7")).Render(iconPi)
	default:
		return theme.dim.Render(glyphAgent)
	}
}

// RenderDetail returns the read-only quest detail pane (no interactive focus).
// Pure and deterministic — golden-testable.
func RenderDetail(q *Quest, runtime Runtime, width int) string {
	return RenderDetailFocused(q, runtime, width, DetailFocus{})
}

// RenderDetailFocused renders the detail pane with an optional interactive
// focus on one row (a toggle gate or a related entry). The board passes an
// active focus when the pane has focus; qm quest view passes none. Layout:
// header (id + status), title, meta line, attached/party line (from runtime),
// objective, definition of done, related, then the body.
func RenderDetailFocused(q *Quest, runtime Runtime, width int, focus DetailFocus) string {
	if width < 1 {
		width = 1
	}
	var b lineWriter

	// Header: id left, status right-aligned to width.
	status := string(q.Status)
	b.add(rowEnds(theme.id.Render(q.ID), theme.statusOf(q.Status).Render(status),
		lipgloss.Width(q.ID), lipgloss.Width(status), width))

	// Title.
	b.add(theme.title.Render(truncate(q.Title, width)))

	// Meta line: glyph-tagged project · date · agent (no redundant "type",
	// they are all quests). The agent glyph carries its brand colour.
	if plain, styled := metaTags(q); len(styled) > 0 {
		b.add(truncateStyled(strings.Join(styled, "   "), strings.Join(plain, "   "), width))
	}

	// Attached / party line (runtime, not the JSON).
	if runtime.Attached() {
		noun := "on it"
		head := fmt.Sprintf("%s %d %s", glyphOnIt, len(runtime.Sessions), noun)
		ses := strings.Join(runtime.Sessions, ", ")
		b.add(truncateStyledPair(theme.flag.Render(head), theme.dim.Render(ses), head, ses, width))
	}

	// Objective (summary).
	b.blank()
	b.add(theme.section.Render("OBJECTIVE"))
	for _, ln := range wrapText(q.Summary, width) {
		b.add(theme.fg.Render(ln))
	}

	// Definition of done (gates). Toggle gates render as [ ] / [x]; auto gates
	// as ◇ (their observed result is overlaid from the sidecar in Stage 2).
	if len(q.Gates) > 0 {
		b.blank()
		b.add(theme.section.Render("DEFINITION OF DONE"))
		for _, ln := range gateLines(q.Gates, width, focus) {
			b.addRaw(ln)
		}
		b.add(theme.faint.Render(truncate("toggles you check "+glyphSep+" autos qm runs "+glyphSep+" you stamp it done", width)))
	}

	// Related — one focusable entry per line.
	if len(q.Related) > 0 {
		b.blank()
		b.add(theme.section.Render("RELATED"))
		for i, r := range q.Related {
			b.addRaw(relatedLine(r, focus.hits(TargetRelated, i), width))
		}
	}

	// Body blocks.
	for _, blk := range q.Body {
		for _, ln := range renderBlock(blk, width) {
			b.addRaw(ln)
		}
	}

	return b.String()
}

// RenderListRow returns one quest-log list line: id, goal, and the derived
// attached/status tag. Fits width on a single line.
func RenderListRow(q *Quest, runtime Runtime, width int) string {
	if width < 1 {
		width = 1
	}
	tag, tagStyle := listTag(q, runtime)
	idW := lipgloss.Width(q.ID)
	tagW := lipgloss.Width(tag)
	// id + "  " + goal + gap + tag
	goalBudget := width - idW - 2 - tagW - 1
	goal := q.Goal()
	if goalBudget < 1 {
		// No room for the goal; keep id and tag.
		left := theme.id.Render(q.ID)
		return rowEnds(left, tagStyle.Render(tag), idW, tagW, width)
	}
	goal = truncate(goal, goalBudget)
	left := theme.id.Render(q.ID) + "  " + theme.muted.Render(goal)
	leftW := idW + 2 + lipgloss.Width(goal)
	return rowEnds(left, tagStyle.Render(tag), leftW, tagW, width)
}

// trackerIDStyle is the quest id on the tracker line: cyan but not bold, so the
// tracker stays visually light (the board keeps its bold id via theme.id).
var trackerIDStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("#4ec3d6"))

// RenderTrackerLine returns the tracker's per-session quest line: "⚑ id · goal",
// no status, no worker line. Fits width.
func RenderTrackerLine(q *Quest, width int) string {
	if width < 1 {
		width = 1
	}
	prefix := glyphFlag + " " + q.ID + " " + glyphSep + " "
	budget := width - lipgloss.Width(prefix)
	goal := q.Goal()
	if budget < 1 {
		return truncate(theme.flag.Render(glyphFlag)+" "+trackerIDStyle.Render(q.ID), width)
	}
	goal = truncate(goal, budget)
	return theme.flag.Render(glyphFlag) + " " +
		trackerIDStyle.Render(q.ID) + " " +
		theme.faint.Render(glyphSep) + " " +
		theme.muted.Render(goal)
}

// relatedTitles returns the display titles of related links, in order.
func relatedTitles(rels []RelatedLink) []string {
	out := make([]string, len(rels))
	for i, r := range rels {
		out[i] = r.Title
	}
	return out
}

// Goal is the one-line objective shown in lists and the tracker. It is the
// summary; the title is the short name.
func (q *Quest) Goal() string {
	if q.Summary != "" {
		return q.Summary
	}
	return q.Title
}

// --- body dispatch -------------------------------------------------------

// renderBlock dispatches one body block to its renderer. Unknown types degrade
// to their fallback (or "[unsupported block]"); they never panic, so a new
// block type does not crash an old binary.
func renderBlock(b Block, width int) []string {
	switch b.Type {
	case BlockHeading:
		return renderHeading(b, width)
	case BlockText:
		return renderTextBlock(b, width)
	case BlockList:
		return renderList(b, width)
	case BlockCode:
		return renderCode(b, width)
	case BlockRich:
		return []string{"", theme.rich.Render(truncate(richPlaceholder(b), width))}
	default:
		fb := b.Fallback
		if fb == "" {
			fb = "[unsupported block]"
		}
		return []string{"", theme.rich.Render(truncate(fb, width))}
	}
}

func renderHeading(b Block, width int) []string {
	indent := ""
	if b.Level > 2 {
		indent = strings.Repeat("  ", b.Level-2)
	}
	body := truncate(indent+b.Text, width)
	return []string{"", theme.heading.Render(body)}
}

func renderTextBlock(b Block, width int) []string {
	out := []string{""}
	for _, ln := range wrapText(b.Text, width) {
		out = append(out, theme.fg.Render(ln))
	}
	return out
}

func renderList(b Block, width int) []string {
	out := []string{""}
	for i, item := range b.Items {
		marker := glyphBullet + " "
		if b.Ordered {
			marker = fmt.Sprintf("%d. ", i+1)
		}
		hang := strings.Repeat(" ", lipgloss.Width(marker))
		wrapped := wrapText(item, max(1, width-lipgloss.Width(marker)))
		for j, ln := range wrapped {
			prefix := marker
			if j > 0 {
				prefix = hang
			}
			out = append(out, theme.muted.Render(prefix+ln))
		}
	}
	return out
}

func renderCode(b Block, width int) []string {
	out := []string{""}
	if b.Lang != "" {
		out = append(out, theme.faint.Render(truncate(b.Lang, width)))
	}
	for _, ln := range strings.Split(b.Text, "\n") {
		out = append(out, theme.dim.Render(truncate("    "+ln, width)))
	}
	return out
}

// richPlaceholder is the single dim line shown for a rich block in the
// terminal, e.g. "[mermaid] route migration order (o to open)".
func richPlaceholder(b Block) string {
	return fmt.Sprintf("[%s] %s (o to open)", b.Format, b.Fallback)
}

// --- shared helpers ------------------------------------------------------

// metaTags builds the glyph-tagged frontmatter segments for the detail pane,
// returning parallel plain and styled slices (so the line can be width-
// truncated by its plain width). "type" is intentionally omitted — everything
// here is a quest.
func metaTags(q *Quest) (plain, styled []string) {
	if q.Project != "" {
		plain = append(plain, glyphProject+" "+q.Project)
		styled = append(styled, theme.dim.Render(glyphProject)+" "+theme.metaVal.Render(q.Project))
	}
	if q.Date != "" {
		plain = append(plain, glyphDate+" "+q.Date)
		styled = append(styled, theme.dim.Render(glyphDate)+" "+theme.metaVal.Render(q.Date))
	}
	if q.Agent != "" {
		plain = append(plain, agentGlyphPlain(q.Agent)+" "+q.Agent)
		styled = append(styled, agentGlyphStyled(q.Agent)+" "+theme.metaVal.Render(q.Agent))
	}
	return plain, styled
}

// listTag returns the derived right-hand tag for a list row and its style:
// on (⚔) when an active quest has sessions, "wait" when active and idle, "wip"
// or "done" for the other statuses.
func listTag(q *Quest, runtime Runtime) (string, lipgloss.Style) {
	switch q.Status {
	case StatusActive:
		if runtime.Attached() {
			return glyphOnIt, theme.flag
		}
		return "wait", theme.dim.Italic(true)
	case StatusDone:
		return "done", theme.faint.Italic(true)
	default:
		return "wip", theme.faint.Italic(true)
	}
}

// focusGutterWidth is the leading column reserved on interactive rows for the
// focus marker, so focused/unfocused rows stay aligned.
const focusGutterWidth = 2

// gateGlyphWidth fixes the glyph column so toggle ([ ]/[x]) and auto (◇) gate
// names align.
const gateGlyphWidth = 3

// gateGlyph returns the per-gate marker: a checkbox for toggle gates (their
// human-authored met-state), a diamond for auto gates (observed elsewhere).
func gateGlyph(g Gate) string {
	if g.Type == GateToggle {
		if g.Checked {
			return "[x]"
		}
		return "[ ]"
	}
	return glyphGate
}

// gateLines renders the definition-of-done table. Each row is
// "<focus> <glyph> name  type  check"; the focused toggle gate (when the pane
// has focus) shows a ▸ marker.
func gateLines(gates []Gate, width int, focus DetailFocus) []string {
	nameW := 0
	for _, g := range gates {
		if w := lipgloss.Width(g.Name); w > nameW {
			nameW = w
		}
	}
	typeW := len("toggle")
	out := make([]string, 0, len(gates))
	for i, g := range gates {
		focused := focus.hits(TargetGate, i)
		glyph := padRightTo(gateGlyph(g), gateGlyphWidth)
		name, typ, check := padRightTo(g.Name, nameW), padRightTo(string(g.Type), typeW), gateCheckText(g)

		plain := focusGutter(focused) + glyph + " " + name + "  " + typ + "  " + check
		glyphStyle := theme.gateGl
		if g.Type == GateToggle && g.Checked {
			glyphStyle = theme.flag // a checked toggle reads "met" (amber)
		}
		styled := focusMarker(focused) +
			glyphStyle.Render(glyph) + " " +
			theme.heading.Render(name) + "  " +
			theme.dim.Render(typ) + "  " +
			theme.dim.Render(check)
		out = append(out, truncateStyled(styled, plain, width))
	}
	return out
}

// relatedLine renders one related entry: "<focus> [type] title", focusable.
func relatedLine(r RelatedLink, focused bool, width int) string {
	badge, badgePlain := "", ""
	if r.Type != "" {
		badge = theme.faint.Render("["+r.Type+"]") + " "
		badgePlain = "[" + r.Type + "] "
	}
	plain := focusGutter(focused) + badgePlain + r.Title
	styled := focusMarker(focused) + badge + theme.id.Render(r.Title)
	return truncateStyled(styled, plain, width)
}

// focusGutter / focusMarker render the leading focus column (plain / styled).
func focusGutter(focused bool) string {
	if focused {
		return "▸ "
	}
	return "  "
}

func focusMarker(focused bool) string {
	if focused {
		return theme.id.Render("▸") + " "
	}
	return "  "
}

func gateCheckText(g Gate) string {
	if g.Check != "" {
		return g.Check
	}
	if g.Before == BeforePR {
		return "before pr"
	}
	return ""
}

// lineWriter accumulates styled lines for a render.
type lineWriter struct{ lines []string }

func (w *lineWriter) add(s string)    { w.lines = append(w.lines, s) }
func (w *lineWriter) addRaw(s string) { w.lines = append(w.lines, s) }
func (w *lineWriter) blank()          { w.lines = append(w.lines, "") }
func (w *lineWriter) String() string  { return strings.Join(w.lines, "\n") }

// rowEnds places left at the start and right at the end of a width-wide line.
// leftW/rightW are the display widths of the (possibly styled) left/right.
func rowEnds(left, right string, leftW, rightW, width int) string {
	gap := width - leftW - rightW
	if gap < 1 {
		// No room: keep the left, drop the trailing element onto the same line.
		gap = 1
	}
	return left + strings.Repeat(" ", gap) + right
}

// truncateStyledPair lays a styled head and a styled tail on one line, with the
// tail right-aligned, truncating the tail if needed.
func truncateStyledPair(headStyled, tailStyled, headPlain, tailPlain string, width int) string {
	hw := lipgloss.Width(headPlain)
	if hw >= width {
		return truncateStyled(headStyled, headPlain, width)
	}
	tail := tailPlain
	if hw+2+lipgloss.Width(tail) > width {
		tail = truncate(tail, width-hw-2)
		tailStyled = theme.dim.Render(tail)
	}
	return headStyled + "  " + tailStyled
}

// padRightTo pads s with spaces to display width w.
func padRightTo(s string, w int) string {
	cur := lipgloss.Width(s)
	if cur >= w {
		return s
	}
	return s + strings.Repeat(" ", w-cur)
}

// truncate trims plain text to display width w, appending "…" when cut.
func truncate(s string, w int) string {
	if w < 1 {
		return ""
	}
	if lipgloss.Width(s) <= w {
		return s
	}
	if w == 1 {
		return "…"
	}
	return ansi.Truncate(s, w, "…")
}

// truncateStyled truncates a styled string to width using its plain-text
// width as the budget. When the plain text fits, the styled form is returned
// unchanged; otherwise the (styled) string is ANSI-truncated.
func truncateStyled(styled, plain string, width int) string {
	if lipgloss.Width(plain) <= width {
		return styled
	}
	return ansi.Truncate(styled, width, "…")
}

// wrapText greedily word-wraps plain text to width, returning at least one line.
func wrapText(s string, width int) []string {
	if width < 1 {
		width = 1
	}
	words := strings.Fields(s)
	if len(words) == 0 {
		return []string{""}
	}
	var lines []string
	cur := words[0]
	for _, w := range words[1:] {
		if lipgloss.Width(cur)+1+lipgloss.Width(w) <= width {
			cur += " " + w
		} else {
			lines = append(lines, cur)
			cur = w
		}
	}
	return append(lines, cur)
}
