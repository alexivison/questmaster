package quest

import (
	"fmt"
	"strings"
	"time"

	"github.com/alexivison/questmaster/internal/palette"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

// Runtime is the derived, render-time state of a quest — which sessions are on
// it — gathered from the session scan and injected at render time. It is never
// stored on the quest itself (one fact, one home: the file holds authored
// content + status; attachment lives on session state).
type Runtime struct {
	// Sessions are the session IDs currently attached to (on) the quest.
	Sessions []string `json:"sessions"`
	// Adventurers is the per-session live activity for the attached sessions, in
	// Sessions order. Populated by the shared runtime scan; renderers fall
	// back to the bare Sessions line when it is empty.
	Adventurers []Adventurer `json:"adventurers"`
	// Agent is derived from the attached session's primary agent at render
	// time. Authored quest JSON does not decide the displayed agent.
	Agent string `json:"agent"`
	// Gates overlays observed auto-gate results (gate name → "pass"/"fail"/
	// "error") from the runtime sidecar. Empty until a check has run. Toggle
	// gates ignore this — their state is authored in the JSON.
	Gates map[string]string `json:"gates,omitempty"`
	// GatesAt overlays each observed auto-gate result's run time, so the
	// renderer can show how fresh a verdict is.
	GatesAt map[string]time.Time `json:"gates_at,omitempty"`
	// ObservedAt is when this runtime was derived. Durations and verdict ages
	// are computed against it, keeping the renderer pure (no global clock).
	ObservedAt time.Time `json:"observed_at"`
	// Loop is present when a visible foreground `qm quest loop` is armed for
	// one of the attached sessions.
	Loop *LoopRuntime `json:"loop,omitempty"`
}

// Attached reports whether any session is on the quest.
func (r Runtime) Attached() bool { return len(r.Sessions) > 0 }

// Adventurer is one attached session's live activity, derived from the
// session scan at render time (never stored on the quest).
type Adventurer struct {
	ID    string `json:"id"`
	Agent string `json:"agent,omitempty"`
	// State is the hook-observed primary-pane state: working | done | blocked
	// | starting | unknown.
	State string `json:"state,omitempty"`
	// Since is when the current state began (WorkingSince for working,
	// otherwise the last state transition).
	Since time.Time `json:"since,omitempty"`
	// Loop is the session's armed loop marker, when present.
	Loop *LoopRuntime `json:"loop,omitempty"`
}

// LoopRuntime is the render-time view of an armed quest loop marker.
type LoopRuntime struct {
	SessionID   string `json:"session_id"`
	Iterations  int    `json:"iterations"`
	LastVerdict string `json:"last_verdict,omitempty"`
	// Phase is what the armed loop is doing right now: waiting | checking |
	// paused. Empty on markers written by older binaries.
	Phase string `json:"phase,omitempty"`
}

// Label returns the compact loop-mode indicator used by tracker and board.
func (l LoopRuntime) Label() string {
	parts := []string{"↻", "loop"}
	if l.Iterations > 0 {
		parts = append(parts, fmt.Sprintf("i%d", l.Iterations))
	}
	if l.LastVerdict != "" {
		parts = append(parts, l.LastVerdict)
	}
	if l.Phase != "" {
		parts = append(parts, glyphSep, l.Phase)
	}
	return strings.Join(parts, " ")
}

// DetailTargetKind identifies an interactive row in the detail pane.
type DetailTargetKind int

const (
	// TargetQuest is the quest-level anchor.
	TargetQuest DetailTargetKind = iota
	// TargetGate is a definition-of-done gate. Only toggle gates are flippable.
	TargetGate
	// TargetRelated is a related entry (openable in T12).
	TargetRelated
	// TargetBody is a body block with a stable id.
	TargetBody
	// TargetListItem is one item inside a list body block.
	TargetListItem
	// TargetComment is an open inline comment row.
	TargetComment
)

// DetailTarget is one interactive row in the detail pane, addressed by its
// index into the matching quest slice. Anchor is the stable comment target for
// rows that can receive a comment. CommentID is set only for open comment rows,
// which can be resolved.
type DetailTarget struct {
	Kind      DetailTargetKind
	Index     int
	ItemIndex int
	Anchor    CommentAnchor
	CommentID string
}

// DetailFocus describes which interactive row the detail pane has focused.
// Active is false for read-only renders (qm quest view); the board sets it
// when the pane has focus. Shared by the board (navigation) and the renderer
// (highlight) so they agree on what is selected.
type DetailFocus struct {
	Active    bool
	Kind      DetailTargetKind
	Index     int
	ItemIndex int
	Anchor    CommentAnchor
	CommentID string
}

// DetailTargets enumerates the interactive rows in display order: quest anchor,
// open quest comments, gates, open gate comments, related entries, open related
// comments, body blocks, and open body comments. Auto gates are focusable but
// remain read-only; only toggle gates flip.
func DetailTargets(q *Quest) []DetailTarget {
	if q == nil {
		return nil
	}
	t := []DetailTarget{{Kind: TargetQuest, Index: -1, Anchor: CommentAnchor{Kind: CommentAnchorQuest}}}
	t = appendCommentTargets(t, q, CommentAnchor{Kind: CommentAnchorQuest})
	for i, g := range q.Gates {
		t = append(t, DetailTarget{Kind: TargetGate, Index: i, Anchor: CommentAnchor{Kind: CommentAnchorGate, ID: g.Name}})
		t = appendCommentTargets(t, q, CommentAnchor{Kind: CommentAnchorGate, ID: g.Name})
	}
	for i, r := range q.Related {
		target := DetailTarget{Kind: TargetRelated, Index: i}
		if r.ID != "" {
			target.Anchor = CommentAnchor{Kind: CommentAnchorRelated, ID: r.ID}
		}
		t = append(t, target)
		if r.ID != "" {
			t = appendCommentTargets(t, q, CommentAnchor{Kind: CommentAnchorRelated, ID: r.ID})
		}
	}
	for i, b := range q.Body {
		if b.Type == BlockList {
			for itemIndex := range b.Items {
				target := DetailTarget{Kind: TargetListItem, Index: i, ItemIndex: itemIndex}
				if b.ID != "" {
					target.Anchor = CommentAnchor{Kind: CommentAnchorBody, ID: b.ID}.WithItem(itemIndex)
				}
				t = append(t, target)
				if b.ID != "" {
					t = appendCommentTargets(t, q, target.Anchor)
				}
			}
			if b.ID != "" {
				t = appendCommentTargets(t, q, CommentAnchor{Kind: CommentAnchorBody, ID: b.ID})
			}
			continue
		}
		target := DetailTarget{Kind: TargetBody, Index: i}
		if b.ID != "" {
			target.Anchor = CommentAnchor{Kind: CommentAnchorBody, ID: b.ID}
		}
		t = append(t, target)
		if b.ID != "" {
			t = appendCommentTargets(t, q, target.Anchor)
		}
	}
	return t
}

func appendCommentTargets(targets []DetailTarget, q *Quest, anchor CommentAnchor) []DetailTarget {
	for i, c := range q.Comments {
		if c.Status == CommentOpen && c.Anchor.equal(anchor) {
			targets = append(targets, DetailTarget{Kind: TargetComment, Index: i, Anchor: c.Anchor, CommentID: c.ID})
		}
	}
	return targets
}

func (f DetailFocus) matches(kind DetailTargetKind, index int, anchor CommentAnchor, commentID string) bool {
	return f.matchesItem(kind, index, -1, anchor, commentID)
}

func (f DetailFocus) matchesItem(kind DetailTargetKind, index, itemIndex int, anchor CommentAnchor, commentID string) bool {
	if !f.Active || f.Kind != kind {
		return false
	}
	if kind == TargetListItem && f.ItemIndex != itemIndex {
		return false
	}
	if commentID != "" || f.CommentID != "" {
		return commentID != "" && f.CommentID == commentID
	}
	if f.Anchor.Kind != "" {
		return f.Anchor.equal(anchor)
	}
	return f.Index == index
}

// Glyphs shared by the three render levels and the HTML build's text fallbacks.
const (
	glyphFlag    = "⚑" // tracker / list: a quest is attached here
	glyphOnIt    = "⚔" // detail / list: sessions are on the quest
	glyphGate    = "◇" // gate diamond
	glyphSep     = "·" // id · goal separators
	glyphBullet  = "·" // unordered list marker
	glyphComment = "✎" // inline quest comment marker
	glyphPipe    = "│" // inline comment thread gutter

	// List-row status glyphs (right column), coloured by status. ● is used for
	// done rather than ✓ to stay distinct from the gate pass glyph.
	glyphActive = "◆" // on the board (active)
	glyphWIP    = "○" // draft (wip)
	glyphDone   = "●" // turned in (done)

	// Meta-line tag glyphs (nerd-font). Agent icons match the tracker exactly.
	glyphProject = ""          // folder — project
	glyphDate    = ""          // calendar — date
	glyphRelated = ""          // link — related tickets
	glyphAgent   = ""          // generic agent fallback
	iconClaude   = "\U000f06c4" // tracker per-agent glyphs
	iconCodex    = ""
	iconOpenCode = "□"
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
	case "opencode":
		return iconOpenCode
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
	case "opencode":
		return lipgloss.NewStyle().Foreground(palette.OpenCodeColor).Render(iconOpenCode)
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
// title + status, meta line, attached/adventurers line (from runtime), objective,
// definition of done, related, then the body.
func RenderDetailFocused(q *Quest, runtime Runtime, width int, focus DetailFocus) string {
	lines, _ := RenderDetailLines(q, runtime, width, focus)
	return strings.Join(lines, "\n")
}

// RenderDetailLines is RenderDetailFocused split into lines plus the index of
// the focused interactive row's line (-1 when the pane is not focused). The
// board uses the index to paint a full-width selection background on that line,
// matching the list; the renderer itself draws no focus marker.
func RenderDetailLines(q *Quest, runtime Runtime, width int, focus DetailFocus) ([]string, int) {
	lines, selection := RenderDetailLineSelection(q, runtime, width, focus)
	return lines, selection.Primary
}

// DetailLineSelection is the set of detail-renderer line indexes that should
// receive selection treatment. Primary is the line used for scroll tracking;
// Lines is the painted set. Most targets select one row, while focused body
// blocks select every rendered content line in the block.
type DetailLineSelection struct {
	Primary int
	Lines   map[int]struct{}
}

// Contains reports whether line should be drawn selected.
func (s DetailLineSelection) Contains(line int) bool {
	_, ok := s.Lines[line]
	return ok
}

func (s *DetailLineSelection) add(line int) {
	if line < 0 {
		return
	}
	if s.Primary == -1 {
		s.Primary = line
	}
	if s.Lines == nil {
		s.Lines = map[int]struct{}{}
	}
	s.Lines[line] = struct{}{}
}

// RenderDetailLineSelection is RenderDetailLines plus the full selected line
// set, used by the board to paint multi-line body block focus.
func RenderDetailLineSelection(q *Quest, runtime Runtime, width int, focus DetailFocus) ([]string, DetailLineSelection) {
	if width < 1 {
		width = 1
	}
	var b lineWriter
	selection := DetailLineSelection{Primary: -1}

	// Header: title left, status right-aligned to width.
	status := string(q.Status)
	statusW := lipgloss.Width(status)
	title := q.titleOrID()
	titleBudget := width - statusW - 1
	if titleBudget < 1 {
		b.add(theme.statusOf(q.Status).Render(truncate(status, width)))
	} else {
		title = truncate(title, titleBudget)
		b.add(rowEnds(theme.title.Render(title), theme.statusOf(q.Status).Render(status),
			lipgloss.Width(title), statusW, width))
	}

	// Meta line: glyph-tagged project · date · agent (no redundant "type",
	// they are all quests). The agent glyph carries its brand colour.
	if plain, styled := metaTags(q, runtime); len(styled) > 0 {
		b.add(truncateStyled(strings.Join(styled, "   "), strings.Join(plain, "   "), width))
	}

	// Attached / adventurers section (runtime, not the JSON). With per-session
	// activity each adventurer renders as one bullet — agent icon, session id,
	// and state duration. Bare Sessions fall back to id-only bullets.
	for _, ln := range attachedLines(runtime, width) {
		b.addRaw(ln)
	}

	// Objective (summary).
	b.blank()
	if focus.matches(TargetQuest, -1, CommentAnchor{Kind: CommentAnchorQuest}, "") {
		selection.add(len(b.lines))
	}
	b.add(theme.section.Render("OBJECTIVE"))
	for _, ln := range wrapText(q.Summary, width) {
		b.add(theme.fg.Render(ln))
	}
	addCommentLines(&b, commentsForAnchor(q, CommentAnchor{Kind: CommentAnchorQuest}), width, focus, &selection)

	// Definition of done (gates). Toggle gates render as [ ] / [x]; auto gates
	// as ◇ (their observed result is overlaid from the sidecar in Stage 2). One
	// line per gate, so the focused gate's line index is gateStart + its index.
	if len(q.Gates) > 0 {
		b.blank()
		b.add(theme.section.Render("DEFINITION OF DONE"))
		for i, ln := range gateLines(q.Gates, width, runtime) {
			anchor := CommentAnchor{Kind: CommentAnchorGate, ID: q.Gates[i].Name}
			if focus.matches(TargetGate, i, anchor, "") {
				selection.add(len(b.lines))
			}
			b.addRaw(ln)
			addCommentLines(&b, commentsForAnchor(q, anchor), width, focus, &selection)
		}
		b.add(theme.faint.Render(truncate("toggles you check "+glyphSep+" autos qm runs "+glyphSep+" you stamp it done", width)))
	}

	// Related — one focusable entry per line.
	if len(q.Related) > 0 {
		b.blank()
		b.add(theme.section.Render("RELATED"))
		for i, r := range q.Related {
			anchor := CommentAnchor{}
			if r.ID != "" {
				anchor = CommentAnchor{Kind: CommentAnchorRelated, ID: r.ID}
			}
			if focus.matches(TargetRelated, i, anchor, "") {
				selection.add(len(b.lines))
			}
			b.addRaw(relatedLine(r, width))
			if r.ID != "" {
				addCommentLines(&b, commentsForAnchor(q, anchor), width, focus, &selection)
			}
		}
	}

	// Body blocks.
	for i, blk := range q.Body {
		anchor := CommentAnchor{}
		if blk.ID != "" {
			anchor = CommentAnchor{Kind: CommentAnchorBody, ID: blk.ID}
		}
		if blk.Type == BlockList {
			b.addRaw("")
			for itemIndex := range blk.Items {
				itemAnchor := CommentAnchor{}
				if blk.ID != "" {
					itemAnchor = anchor.WithItem(itemIndex)
				}
				itemStart := len(b.lines)
				for _, ln := range renderListItem(blk, itemIndex, width) {
					b.addRaw(ln)
				}
				if focus.matchesItem(TargetListItem, i, itemIndex, itemAnchor, "") {
					for line := itemStart; line < len(b.lines); line++ {
						selection.add(line)
					}
				}
				if blk.ID != "" {
					addCommentLines(&b, commentsForAnchor(q, itemAnchor), width, focus, &selection)
				}
			}
			if blk.ID != "" {
				addCommentLines(&b, commentsForAnchor(q, anchor), width, focus, &selection)
			}
			continue
		}
		lines := renderBlock(blk, width)
		var blockLines []int
		for _, ln := range lines {
			if strings.TrimSpace(ansi.Strip(ln)) != "" {
				blockLines = append(blockLines, len(b.lines))
			}
			b.addRaw(ln)
		}
		if focus.matches(TargetBody, i, anchor, "") {
			for _, line := range blockLines {
				selection.add(line)
			}
		}
		if blk.ID != "" {
			addCommentLines(&b, commentsForAnchor(q, anchor), width, focus, &selection)
		}
	}

	return b.lines, selection
}

// listTitleStyle is the list-row title: the detail title's white (theme.title),
// but not bold — a row in a dense list reads lighter without the weight.
var listTitleStyle = theme.title.Bold(false)

// ListTagMode selects the right-column marker for a list row.
type ListTagMode int

const (
	// TagStatus shows the colour-coded status glyph (◆/○/●, ⚔ when attached).
	// Used by `quest ls`, which has no tabs to convey status.
	TagStatus ListTagMode = iota
	// TagAttached shows only the ⚔ on-it marker (blank otherwise). Used by the
	// board, where the selected status tab already conveys status.
	TagAttached
)

// RenderListRow returns one quest-log list line: id, goal, and the right-column
// marker selected by mode. Fits width on a single line.
func RenderListRow(q *Quest, runtime Runtime, width int, mode ListTagMode) string {
	if width < 1 {
		width = 1
	}
	tag, tagStyle := listTag(q, runtime, mode)
	idW := lipgloss.Width(q.ID)
	tagW := lipgloss.Width(tag)
	// id + "  " + title + gap + tag
	budget := width - idW - 2 - tagW - 1
	title := q.titleOrID()
	if budget < 1 {
		// No room for the title; keep id and tag.
		left := listIDStyle(q.Status).Render(q.ID)
		return rowEnds(left, tagStyle.Render(tag), idW, tagW, width)
	}
	title = truncate(title, budget)
	left := listIDStyle(q.Status).Render(q.ID) + "  " + listTitleStyle.Render(title)
	leftW := idW + 2 + lipgloss.Width(title)
	return rowEnds(left, tagStyle.Render(tag), leftW, tagW, width)
}

// RenderBoardListRows returns the board's two-line row: title first, quest id
// below. The board supplies outer gutters and selection backgrounds.
func RenderBoardListRows(q *Quest, runtime Runtime, width int) []string {
	if width < 1 {
		width = 1
	}
	tag, tagStyle := listTag(q, runtime, TagAttached)
	tagW := lipgloss.Width(tag)
	titleBudget := width
	if tagW > 0 {
		titleBudget = width - tagW - 1
		if titleBudget < 1 {
			tag = ""
			tagW = 0
			titleBudget = width
		}
	}
	title := truncate(q.titleOrID(), titleBudget)
	titleLine := rowEnds(listTitleStyle.Render(title), tagStyle.Render(tag), lipgloss.Width(title), tagW, width)

	id := truncate(q.ID, width)
	return []string{
		titleLine,
		boardListIDStyle.Render(id),
	}
}

// trackerIDStyle is the quest id on the tracker line: cyan but not bold, so the
// tracker stays visually light.
var trackerIDStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("#4ec3d6"))

// RenderTrackerLine returns the tracker's per-session quest line: "⚑ id · goal",
// no status. Fits width.
func RenderTrackerLine(q *Quest, width int) string {
	if width < 1 {
		width = 1
	}
	prefix := glyphFlag + " " + q.ID + " " + glyphSep + " "
	budget := width - lipgloss.Width(prefix)
	title := q.titleOrID()
	if budget < 1 {
		return truncate(theme.flag.Render(glyphFlag)+" "+trackerIDStyle.Render(q.ID), width)
	}
	title = truncate(title, budget)
	return theme.flag.Render(glyphFlag) + " " +
		trackerIDStyle.Render(q.ID) + " " +
		theme.faint.Render(glyphSep) + " " +
		theme.muted.Render(title)
}

// relatedTitles returns the display titles of related links, in order.
func relatedTitles(rels []RelatedLink) []string {
	out := make([]string, len(rels))
	for i, r := range rels {
		out[i] = r.Title
	}
	return out
}

// Goal is the one-line objective. It is the summary; falls back to the title.
// Used by the working-clause brief.
func (q *Quest) Goal() string {
	if q.Summary != "" {
		return q.Summary
	}
	return q.Title
}

// titleOrID is the short name shown in the list and tracker lines: the title,
// or the id when a title is somehow absent.
func (q *Quest) titleOrID() string {
	if q.Title != "" {
		return q.Title
	}
	return q.ID
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
	for i := range b.Items {
		out = append(out, renderListItem(b, i, width)...)
	}
	return out
}

func renderListItem(b Block, itemIndex, width int) []string {
	if b.Type != BlockList || itemIndex < 0 || itemIndex >= len(b.Items) {
		return nil
	}
	marker := glyphBullet + " "
	if b.Ordered {
		marker = fmt.Sprintf("%d. ", itemIndex+1)
	}
	hang := strings.Repeat(" ", lipgloss.Width(marker))
	wrapped := wrapText(b.Items[itemIndex], max(1, width-lipgloss.Width(marker)))
	out := make([]string, 0, len(wrapped))
	for j, ln := range wrapped {
		prefix := marker
		if j > 0 {
			prefix = hang
		}
		out = append(out, theme.fg.Render(prefix+ln))
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
func metaTags(q *Quest, runtime Runtime) (plain, styled []string) {
	if q.ID != "" {
		plain = append(plain, "# "+q.ID)
		styled = append(styled, theme.dim.Render("#")+" "+boardListIDStyle.Render(q.ID))
	}
	if q.Project != "" {
		plain = append(plain, glyphProject+" "+q.Project)
		styled = append(styled, theme.dim.Render(glyphProject)+" "+theme.metaVal.Render(q.Project))
	}
	if q.Date != "" {
		plain = append(plain, glyphDate+" "+q.Date)
		styled = append(styled, theme.dim.Render(glyphDate)+" "+theme.metaVal.Render(q.Date))
	}
	agentName := runtime.Agent
	if agentName != "" {
		plain = append(plain, agentGlyphPlain(agentName)+" "+agentName)
		styled = append(styled, agentGlyphStyled(agentName)+" "+theme.metaVal.Render(agentName))
	}
	return plain, styled
}

// listTag returns the right-column marker for a list row and its style. ⚔
// (amber) marks an active quest with a worker on it in both modes. In
// TagAttached (board) that is the only marker — status is conveyed by the
// selected tab — so everything else is blank. In TagStatus (`quest ls`) the
// status glyph stands in: ◆ on the board, ○ draft, ● turned in.
func listTag(q *Quest, runtime Runtime, mode ListTagMode) (string, lipgloss.Style) {
	openTag := openCommentTag(q)
	if q.Status == StatusActive && runtime.Attached() {
		if openTag != "" {
			return glyphOnIt + " " + openTag, theme.flag
		}
		return glyphOnIt, theme.flag
	}
	if mode == TagAttached {
		return openTag, theme.flag
	}
	status := statusGlyph(q.Status)
	if openTag != "" {
		return status + " " + openTag, theme.statusOf(q.Status)
	}
	return status, theme.statusOf(q.Status)
}

func openCommentTag(q *Quest) string {
	n := OpenCommentCount(q)
	if n == 0 {
		return ""
	}
	return fmt.Sprintf("%s %d", glyphComment, n)
}

// statusGlyph is the list-row marker for a status.
func statusGlyph(s Status) string {
	switch s {
	case StatusActive:
		return glyphActive
	case StatusDone:
		return glyphDone
	default: // wip
		return glyphWIP
	}
}

// gateGlyphWidth fixes the glyph column so toggle ([ ]/[x]) and auto (◇) gate
// names align.
const gateGlyphWidth = 3

// gateGlyph returns the authored per-gate marker: a checkbox for toggle gates
// (their human-authored met-state), a diamond for auto gates. Used by the HTML
// build (the plan) — the terminal overlays observed auto results via
// gateDisplayGlyph.
func gateGlyph(g Gate) string {
	if g.Type == GateToggle {
		if g.Checked {
			return "[x]"
		}
		return "[ ]"
	}
	return glyphGate
}

// auto-result glyph styles (overlaid in the terminal from the sidecar).
var (
	gatePassStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("#82d273"))
	gateErrStyle  = lipgloss.NewStyle().Foreground(lipgloss.Color("#e6b860"))
)

// gateDisplayGlyph returns the terminal glyph + style for a gate. Toggle gates
// show their authored checkbox; auto gates overlay the observed result from the
// sidecar (✓ pass, ✗ fail, ⚠ misconfigured) or ◇ when not yet run. The glyph
// colour follows the gate type; the result shape carries the verdict.
func gateDisplayGlyph(g Gate, result string) (string, lipgloss.Style) {
	style := gateTypeStyle(g.Type)
	if g.Type == GateToggle {
		if g.Checked {
			return "[x]", style
		}
		return "[ ]", style
	}
	switch result {
	case "pass":
		return "✓", style
	case "fail":
		return "✗", style
	case "error":
		return "⚠", style
	default:
		return glyphGate, style
	}
}

// gateLines renders the definition-of-done table. Each row is
// "<glyph> name  type  check" (one line per gate), with an observed verdict's
// age appended when known. The board paints a background on the focused row;
// the renderer draws no marker. runtime overlays observed auto-gate verdicts
// and their run times.
func gateLines(gates []Gate, width int, runtime Runtime) []string {
	nameW := 0
	for _, g := range gates {
		if w := lipgloss.Width(g.Name); w > nameW {
			nameW = w
		}
	}
	typeW := len("toggle")
	out := make([]string, 0, len(gates))
	for _, g := range gates {
		rawGlyph, glyphStyle := gateDisplayGlyph(g, runtime.Gates[g.Name])
		glyph := padRightTo(rawGlyph, gateGlyphWidth)
		name, typ, check := padRightTo(g.Name, nameW), padRightTo(string(g.Type), typeW), gateCheckText(g)
		age := gateAgeText(g, runtime)
		typeStyle := gateTypeStyle(g.Type)

		plain := glyph + " " + name + "  " + typ + "  " + check + age
		styled := glyphStyle.Render(glyph) + " " +
			theme.heading.Render(name) + "  " +
			typeStyle.Render(typ) + "  " +
			theme.dim.Render(check) +
			theme.faint.Render(age)
		out = append(out, truncateStyled(styled, plain, width))
	}
	return out
}

// gateAgeText is the freshness suffix for an observed auto-gate verdict, e.g.
// " · 2m ago". Empty for toggle gates, unobserved gates, and runtimes without
// an observation clock — a green from yesterday must not read like one from
// ten seconds ago.
func gateAgeText(g Gate, runtime Runtime) string {
	if g.Type != GateAuto || runtime.ObservedAt.IsZero() {
		return ""
	}
	ranAt, ok := runtime.GatesAt[g.Name]
	if !ok || ranAt.IsZero() {
		return ""
	}
	return "  " + glyphSep + " " + agoLabel(runtime.ObservedAt.Sub(ranAt))
}

func attachedLines(runtime Runtime, width int) []string {
	count := len(runtime.Adventurers)
	if count == 0 {
		count = len(runtime.Sessions)
	}
	if count == 0 {
		return nil
	}

	out := []string{theme.faint.Render(strings.Repeat("─", width))}
	head := fmt.Sprintf("%s %d on it:", glyphOnIt, count)
	out = append(out, theme.flag.Render(truncate(head, width)))
	if len(runtime.Adventurers) > 0 {
		for _, sr := range runtime.Adventurers {
			out = append(out, adventurerLine(sr, runtime.ObservedAt, width))
		}
	} else {
		for _, id := range runtime.Sessions {
			out = append(out, sessionLine(id, width))
		}
	}
	out = append(out, theme.faint.Render(strings.Repeat("─", width)))
	return out
}

// adventurerLine renders one adventurer's live activity under the on-it head:
// "- 󰛄 qm-x · working 2m14s".
func adventurerLine(sr Adventurer, observedAt time.Time, width int) string {
	stateLabel := adventurerStateLabel(sr, observedAt)

	glyph := agentGlyphPlain(sr.Agent)
	styledGlyph := agentGlyphStyled(sr.Agent)
	plain := "- " + glyph + " " + sr.ID + " " + glyphSep + " " + stateLabel
	styled := theme.dim.Render("- ") +
		styledGlyph + " " +
		theme.metaVal.Render(sr.ID) + " " +
		theme.faint.Render(glyphSep) + " " +
		adventurerStateStyle(sr.State).Render(stateLabel)
	return truncateStyled(styled, plain, width)
}

func sessionLine(id string, width int) string {
	plain := "- " + id
	styled := theme.dim.Render("- ") + theme.metaVal.Render(id)
	return truncateStyled(styled, plain, width)
}

// adventurerStateLabel is the display word for a session's hook state plus how
// long it has held it ("done" reads as idle — the turn ended, the session
// waits). The duration needs both ends of the clock; either missing omits it.
func adventurerStateLabel(sr Adventurer, observedAt time.Time) string {
	label := sr.State
	switch sr.State {
	case "":
		label = "unknown"
	case "done":
		label = "idle"
	}
	if !sr.Since.IsZero() && !observedAt.IsZero() && observedAt.After(sr.Since) {
		label += " " + compactDuration(observedAt.Sub(sr.Since))
	}
	return label
}

func adventurerStateStyle(state string) lipgloss.Style {
	switch state {
	case "working":
		return gatePassStyle
	case "blocked":
		return gateErrStyle
	default:
		return theme.dim
	}
}

// compactDuration formats a live duration the way the tracker does: 37s,
// 2m14s, 1h12m.
func compactDuration(d time.Duration) string {
	if d < 0 {
		d = 0
	}
	switch {
	case d < time.Minute:
		return fmt.Sprintf("%ds", int(d.Seconds()))
	case d < time.Hour:
		return fmt.Sprintf("%dm%02ds", int(d.Minutes()), int(d.Seconds())%60)
	default:
		return fmt.Sprintf("%dh%02dm", int(d.Hours()), int(d.Minutes())%60)
	}
}

// agoLabel formats a verdict's age: just now, 37s ago, 2m ago, 3h ago, 2d ago.
func agoLabel(d time.Duration) string {
	switch {
	case d < 5*time.Second:
		return "just now"
	case d < time.Minute:
		return fmt.Sprintf("%ds ago", int(d.Seconds()))
	case d < time.Hour:
		return fmt.Sprintf("%dm ago", int(d.Minutes()))
	case d < 24*time.Hour:
		return fmt.Sprintf("%dh ago", int(d.Hours()))
	default:
		return fmt.Sprintf("%dd ago", int(d.Hours()/24))
	}
}

// relatedLine renders one related entry: "[type] title".
func relatedLine(r RelatedLink, width int) string {
	badge, badgePlain := "", ""
	if r.Type != "" {
		badge = theme.faint.Render("["+r.Type+"]") + " "
		badgePlain = "[" + r.Type + "] "
	}
	plain := badgePlain + r.Title
	styled := badge + theme.id.Render(r.Title)
	return truncateStyled(styled, plain, width)
}

func addCommentLines(b *lineWriter, comments []QuestComment, width int, focus DetailFocus, selection *DetailLineSelection) {
	for _, c := range comments {
		lines := commentLine(c, width)
		if focus.matches(TargetComment, -1, c.Anchor, c.ID) {
			start := len(b.lines)
			for line := start; line < start+len(lines); line++ {
				selection.add(line)
			}
		}
		for _, ln := range lines {
			b.addRaw(ln)
		}
	}
}

func commentLine(c QuestComment, width int) []string {
	meta := string(c.Status)
	if c.Author != "" {
		meta += " by " + c.Author
	}
	pipe := theme.faint.Render(glyphPipe)
	headPlain := glyphComment + " " + c.ID + " " + glyphSep + " " + meta
	headStyled := theme.comment.Render(glyphComment+" "+c.ID) + " " + theme.faint.Render(glyphSep) + " " + theme.dim.Render(meta)
	out := []string{truncateStyled(headStyled, headPlain, width)}

	bodyPrefix := glyphPipe + " "
	bodyWidth := width - lipgloss.Width(bodyPrefix)
	if bodyWidth < 1 {
		bodyWidth = 1
	}
	for _, raw := range strings.Split(strings.TrimSpace(c.Body), "\n") {
		for _, ln := range wrapText(raw, bodyWidth) {
			plain := bodyPrefix + ln
			styled := pipe + " " + theme.fg.Render(ln)
			out = append(out, truncateStyled(styled, plain, width))
		}
	}
	return out
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
