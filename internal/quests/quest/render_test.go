package quest

import (
	"flag"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
	"github.com/muesli/termenv"
)

var update = flag.Bool("update", false, "update golden files")

func strip(s string) string { return ansi.Strip(s) }

func lineContaining(t *testing.T, lines []string, needle string) int {
	t.Helper()
	for i, line := range lines {
		if strings.Contains(strip(line), needle) {
			return i
		}
	}
	t.Fatalf("no rendered line contains %q:\n%s", needle, strip(strings.Join(lines, "\n")))
	return -1
}

// goldenEq compares ANSI-stripped output to a golden file, regenerating it
// under -update. Golden files are the renderer's verifiability gate.
func goldenEq(t *testing.T, name, got string) {
	t.Helper()
	got = strip(got)
	path := filepath.Join("testdata", name)
	if *update {
		if err := os.WriteFile(path, []byte(got), 0o644); err != nil {
			t.Fatalf("write golden %s: %v", name, err)
		}
		return
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read golden %s: %v (run -update)", name, err)
	}
	if got != string(want) {
		t.Errorf("%s mismatch:\n--- got ---\n%s\n--- want ---\n%s", name, got, want)
	}
}

func TestRenderDetailGolden(t *testing.T) {
	q := workedExample()
	rt := Runtime{Sessions: []string{"qm-1780292528", "qm-1780295973"}}
	goldenEq(t, "detail.golden", RenderDetail(q, rt, 72))
}

func TestRenderBlockDispatch(t *testing.T) {
	cases := []struct {
		name string
		blk  Block
		want []string
	}{
		{"heading", Block{Type: BlockHeading, Level: 2, Text: "Context"}, []string{"", "Context"}},
		{"heading-indent", Block{Type: BlockHeading, Level: 3, Text: "Sub"}, []string{"", "  Sub"}},
		{"text", Block{Type: BlockText, Text: "hello world"}, []string{"", "hello world"}},
		{"list-ordered", Block{Type: BlockList, Ordered: true, Items: []string{"a", "b"}}, []string{"", "1. a", "2. b"}},
		{"list-unordered", Block{Type: BlockList, Items: []string{"a"}}, []string{"", "· a"}},
		{"code", Block{Type: BlockCode, Lang: "go", Text: "x := 1"}, []string{"", "go", "    x := 1"}},
		{"rich", Block{Type: BlockRich, Format: "mermaid", Fallback: "route order"}, []string{"", "[mermaid] route order (o to open)"}},
		{"unknown-with-fallback", Block{Type: "timeline", Fallback: "a timeline"}, []string{"", "a timeline"}},
		{"unknown-no-fallback", Block{Type: "timeline"}, []string{"", "[unsupported block]"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := renderBlock(c.blk, 80)
			for i := range got {
				got[i] = strip(got[i])
			}
			if !reflect.DeepEqual(got, c.want) {
				t.Errorf("renderBlock(%s) = %#v, want %#v", c.name, got, c.want)
			}
		})
	}
}

func TestRenderListItemUsesBodyCopyStyle(t *testing.T) {
	lipgloss.SetColorProfile(termenv.TrueColor)
	t.Cleanup(func() { lipgloss.SetColorProfile(termenv.Ascii) })

	got := renderListItem(Block{Type: BlockList, Items: []string{"body copy"}}, 0, 80)
	if len(got) != 1 {
		t.Fatalf("renderListItem lines = %#v, want one line", got)
	}
	want := theme.fg.Render(glyphBullet + " body copy")
	if got[0] != want {
		t.Fatalf("list item should use body copy style:\n got %q\nwant %q", got[0], want)
	}
}

func TestRenderBlockNeverPanics(t *testing.T) {
	// An old binary meeting a new block type must degrade, not crash.
	defer func() {
		if r := recover(); r != nil {
			t.Fatalf("renderBlock panicked on unknown type: %v", r)
		}
	}()
	_ = renderBlock(Block{Type: "from-the-future", Content: "x"}, 40)
}

func TestRenderTrackerLine(t *testing.T) {
	// The tracker line shows the title (not the summary).
	q := &Quest{ID: "DEMO-1", Title: "Widget shell refactor", Summary: "the long objective"}
	got := strip(RenderTrackerLine(q, 60))
	want := "⚑ DEMO-1 · Widget shell refactor"
	if got != want {
		t.Errorf("RenderTrackerLine = %q, want %q", got, want)
	}
}

func TestRenderTrackerLineTruncates(t *testing.T) {
	q := &Quest{ID: "DEMO-1", Title: strings.Repeat("x", 200)}
	got := strip(RenderTrackerLine(q, 30))
	if w := ansi.StringWidth(got); w > 30 {
		t.Errorf("RenderTrackerLine width = %d, want <= 30 (%q)", w, got)
	}
	if !strings.HasPrefix(got, "⚑ DEMO-1 · ") {
		t.Errorf("RenderTrackerLine lost its prefix: %q", got)
	}
}

func TestRenderListRowTagStatus(t *testing.T) {
	// TagStatus (`quest ls`): status glyph per row, ⚔ when attached.
	cases := []struct {
		name     string
		status   Status
		attached bool
		wantTag  string
	}{
		{"active-on", StatusActive, true, "⚔"},
		{"active-wait", StatusActive, false, "◆"},
		{"wip", StatusWIP, false, "○"},
		{"done", StatusDone, false, "●"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			q := &Quest{ID: "DEMO-1", Title: "Widget shell refactor", Summary: "the long objective", Status: c.status}
			rt := Runtime{}
			if c.attached {
				rt.Sessions = []string{"qm-1"}
			}
			got := strip(RenderListRow(q, rt, 60, TagStatus))
			if !strings.HasPrefix(got, "DEMO-1  ") {
				t.Errorf("row lost its id prefix: %q", got)
			}
			if !strings.HasSuffix(got, c.wantTag) {
				t.Errorf("row %q does not end with tag %q", got, c.wantTag)
			}
			// The list shows the title, not the summary.
			if !strings.Contains(got, "Widget shell refactor") {
				t.Errorf("row %q lost the title", got)
			}
			if strings.Contains(got, "long objective") {
				t.Errorf("row %q should show the title, not the summary", got)
			}
		})
	}
}

func TestRenderListRowTagAttached(t *testing.T) {
	// TagAttached (board): only ⚔ for an active+attached quest; status glyphs
	// are gone (the tab conveys status).
	q := &Quest{ID: "DEMO-1", Title: "Widget shell refactor", Summary: "s", Status: StatusActive}

	attached := strip(RenderListRow(q, Runtime{Sessions: []string{"qm-1"}}, 60, TagAttached))
	if !strings.HasSuffix(strings.TrimRight(attached, " "), "⚔") {
		t.Errorf("attached active row should end with ⚔: %q", attached)
	}

	for _, status := range []Status{StatusActive, StatusWIP, StatusDone} {
		q.Status = status
		got := strip(RenderListRow(q, Runtime{}, 60, TagAttached))
		for _, glyph := range []string{"◆", "○", "●", "⚔"} {
			if strings.Contains(got, glyph) {
				t.Errorf("unattached %s board row should have no marker, found %q in %q", status, glyph, got)
			}
		}
		if !strings.Contains(got, "Widget shell refactor") {
			t.Errorf("board row lost the title: %q", got)
		}
	}
}

func TestRenderListRowIDColorByStatus(t *testing.T) {
	lipgloss.SetColorProfile(termenv.TrueColor)
	t.Cleanup(func() { lipgloss.SetColorProfile(termenv.Ascii) })

	cases := []struct {
		status Status
		style  lipgloss.Style
	}{
		{StatusActive, lipgloss.NewStyle().Foreground(lipgloss.Color("#e6b860")).Bold(true)},
		{StatusWIP, lipgloss.NewStyle().Foreground(lipgloss.Color("#5a6577")).Bold(true)},
		{StatusDone, lipgloss.NewStyle().Foreground(lipgloss.Color("#5a6577")).Bold(true)},
	}
	for _, c := range cases {
		t.Run(string(c.status), func(t *testing.T) {
			q := &Quest{ID: "DEMO-1", Title: "Widget shell refactor", Summary: "s", Status: c.status}
			got := RenderListRow(q, Runtime{}, 60, TagStatus)
			wantID := c.style.Render(q.ID)
			if !strings.Contains(got, wantID) {
				t.Fatalf("list row for %s missing styled id %q:\n%q", c.status, wantID, got)
			}
		})
	}
}

func TestGateGlyphCheckbox(t *testing.T) {
	if g := gateGlyph(Gate{Type: GateToggle}); g != "[ ]" {
		t.Errorf("unchecked toggle glyph = %q, want [ ]", g)
	}
	if g := gateGlyph(Gate{Type: GateToggle, Checked: true}); g != "[x]" {
		t.Errorf("checked toggle glyph = %q, want [x]", g)
	}
	if g := gateGlyph(Gate{Type: GateAuto, Check: "x"}); g != glyphGate {
		t.Errorf("auto glyph = %q, want %q", g, glyphGate)
	}
}

func TestRenderDetailShowsCheckboxes(t *testing.T) {
	q := &Quest{ID: "X", Title: "t", Summary: "s", Status: StatusActive,
		Gates: []Gate{{Name: " a", Type: GateToggle, Checked: true}, {Name: "b", Type: GateToggle}}}
	got := strip(RenderDetail(q, Runtime{}, 60))
	if !strings.Contains(got, "[x]") || !strings.Contains(got, "[ ]") {
		t.Errorf("detail missing checkbox glyphs:\n%s", got)
	}
}

func TestRenderDetailShowsAnchoredOpenComments(t *testing.T) {
	q := &Quest{
		ID:      "COMMENT-1",
		Title:   "Commented",
		Summary: "s",
		Status:  StatusActive,
		Gates:   []Gate{{Name: "review", Type: GateToggle}},
		Related: []RelatedLink{{ID: "rel-1", Title: "TASK-1"}},
		Body:    []Block{{ID: "body-1", Type: BlockText, Text: "body text"}},
		Comments: []QuestComment{
			{ID: "comment-quest", Anchor: CommentAnchor{Kind: CommentAnchorQuest}, Status: CommentOpen, Body: "quest note", CreatedAt: "2026-06-17T00:00:00Z"},
			{ID: "comment-gate", Anchor: CommentAnchor{Kind: CommentAnchorGate, ID: "review"}, Status: CommentOpen, Author: "aleksi", Body: "gate note", CreatedAt: "2026-06-17T00:01:00Z"},
			{ID: "comment-related", Anchor: CommentAnchor{Kind: CommentAnchorRelated, ID: "rel-1"}, Status: CommentOpen, Body: "related note", CreatedAt: "2026-06-17T00:02:00Z"},
			{ID: "comment-body", Anchor: CommentAnchor{Kind: CommentAnchorBody, ID: "body-1"}, Status: CommentOpen, Body: "body note", CreatedAt: "2026-06-17T00:03:00Z"},
			{ID: "comment-resolved", Anchor: CommentAnchor{Kind: CommentAnchorQuest}, Status: CommentResolved, Body: "resolved note", CreatedAt: "2026-06-17T00:04:00Z"},
		},
	}
	got := strip(RenderDetail(q, Runtime{}, 80))
	for _, want := range []string{"✎ comment-quest", "quest note", "✎ comment-gate · open by aleksi", "gate note", "TASK-1", "related note", "body text", "body note"} {
		if !strings.Contains(got, want) {
			t.Fatalf("detail render missing %q:\n%s", want, got)
		}
	}
	if strings.Contains(got, "resolved note") {
		t.Fatalf("detail render should not show resolved comments in the inline slice:\n%s", got)
	}
}

func TestCommentLineRendersPipeGutter(t *testing.T) {
	got := strip(strings.Join(commentLine(QuestComment{
		ID:     "comment-1",
		Status: CommentOpen,
		Body:   "first line\nsecond line",
	}, 80), "\n"))
	for _, want := range []string{
		"✎ comment-1 · open",
		"│ first line",
		"│ second line",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("comment line missing pipe gutter fragment %q:\n%s", want, got)
		}
	}
	if strings.Contains(got, "│ ✎") {
		t.Fatalf("comment header should not include the gutter pipe:\n%s", got)
	}
}

func TestRenderDetailShowsListItemCommentsBelowItem(t *testing.T) {
	q := &Quest{
		ID:      "COMMENT-1",
		Title:   "Commented",
		Summary: "s",
		Status:  StatusActive,
		Body: []Block{{
			ID:    "steps",
			Type:  BlockList,
			Items: []string{"first step", "second step"},
		}},
		Comments: []QuestComment{
			{ID: "comment-item", Anchor: CommentAnchor{Kind: CommentAnchorBody, ID: "steps"}.WithItem(0), Status: CommentOpen, Body: "first item note", CreatedAt: "2026-06-17T00:00:00Z"},
			{ID: "comment-block", Anchor: CommentAnchor{Kind: CommentAnchorBody, ID: "steps"}, Status: CommentOpen, Body: "whole list note", CreatedAt: "2026-06-17T00:01:00Z"},
		},
	}
	got := strip(RenderDetail(q, Runtime{}, 80))
	first := strings.Index(got, "first step")
	itemComment := strings.Index(got, "first item note")
	second := strings.Index(got, "second step")
	blockComment := strings.Index(got, "whole list note")
	if first < 0 || itemComment < 0 || second < 0 || blockComment < 0 {
		t.Fatalf("detail render missing list/comment text:\n%s", got)
	}
	if !(first < itemComment && itemComment < second && second < blockComment) {
		t.Fatalf("list comment order wrong, want item comment under first item and block comment after list:\n%s", got)
	}
}

func TestRenderListRowsShowCompactOpenCommentCount(t *testing.T) {
	q := &Quest{
		ID:      "COMMENT-1",
		Title:   "Commented",
		Summary: "s",
		Status:  StatusActive,
		Comments: []QuestComment{
			{ID: "comment-open", Anchor: CommentAnchor{Kind: CommentAnchorQuest}, Status: CommentOpen, Body: "open", CreatedAt: "2026-06-17T00:00:00Z"},
			{ID: "comment-resolved", Anchor: CommentAnchor{Kind: CommentAnchorQuest}, Status: CommentResolved, Body: "resolved", CreatedAt: "2026-06-17T00:01:00Z"},
		},
	}
	if got := strip(RenderListRow(q, Runtime{}, 80, TagStatus)); !strings.Contains(got, "✎ 1") || strings.Contains(got, "1 open") {
		t.Fatalf("list row should show compact open comment count:\n%s", got)
	}
	boardRows := RenderBoardListRows(q, Runtime{}, 80)
	if got := strip(strings.Join(boardRows, "\n")); !strings.Contains(got, "✎ 1") || strings.Contains(got, "1 open") {
		t.Fatalf("board list row should show compact open comment count:\n%s", got)
	}
}

func TestRenderDetailDerivesAgentFromRuntimeWhenQuestAgentEmpty(t *testing.T) {
	q := &Quest{ID: "X", Title: "t", Summary: "s", Status: StatusActive}
	got := strip(RenderDetail(q, Runtime{Agent: "claude", Sessions: []string{"qm-1"}}, 60))
	if !strings.Contains(got, "claude") {
		t.Fatalf("detail missing runtime-derived agent:\n%s", got)
	}
	if q.Agent != "" {
		t.Fatalf("RenderDetail mutated quest agent to %q", q.Agent)
	}
}

func TestRenderDetailIgnoresExplicitQuestAgent(t *testing.T) {
	q := &Quest{ID: "X", Title: "t", Summary: "s", Status: StatusActive, Agent: "codex"}
	got := strip(RenderDetail(q, Runtime{Agent: "claude"}, 60))
	if !strings.Contains(got, "claude") {
		t.Fatalf("detail missing runtime agent:\n%s", got)
	}
	if strings.Contains(got, "codex") {
		t.Fatalf("detail should not show legacy authored agent:\n%s", got)
	}
}

func TestRenderDetailLinesReportsFocusedLine(t *testing.T) {
	q := &Quest{ID: "X", Title: "t", Summary: "s", Status: StatusActive,
		Gates: []Gate{
			{Name: "tests", Type: GateAuto, Check: "cmd:make test"}, // index 0, skipped
			{Name: "ui-ok", Type: GateToggle},                       // index 1, the target
		}}
	// No focus → -1.
	if _, fl := RenderDetailLines(q, Runtime{}, 60, DetailFocus{}); fl != -1 {
		t.Errorf("unfocused render reported focused line %d, want -1", fl)
	}
	// Focus the toggle gate (gate-array index 1).
	lines, fl := RenderDetailLines(q, Runtime{}, 60, DetailFocus{Active: true, Kind: TargetGate, Index: 1})
	if fl < 0 || fl >= len(lines) {
		t.Fatalf("focused line index %d out of range (%d lines)", fl, len(lines))
	}
	if !strings.Contains(strip(lines[fl]), "ui-ok") {
		t.Errorf("focused line %q is not the ui-ok gate", strip(lines[fl]))
	}
}

func TestRenderDetailLinesFocusesBodyAndCommentTargets(t *testing.T) {
	q := &Quest{
		ID:      "X",
		Title:   "t",
		Summary: "s",
		Status:  StatusActive,
		Body:    []Block{{ID: "block-1", Type: BlockText, Text: "body text"}},
		Comments: []QuestComment{{
			ID:        "comment-1",
			Anchor:    CommentAnchor{Kind: CommentAnchorBody, ID: "block-1"},
			Status:    CommentOpen,
			Body:      "comment body",
			CreatedAt: "2026-06-17T00:00:00Z",
		}},
	}
	bodyAnchor := CommentAnchor{Kind: CommentAnchorBody, ID: "block-1"}
	lines, fl := RenderDetailLines(q, Runtime{}, 60, DetailFocus{Active: true, Kind: TargetBody, Index: 0, Anchor: bodyAnchor})
	if fl < 0 || !strings.Contains(strip(lines[fl]), "body text") {
		t.Fatalf("body focus landed on line %d (%q), want body text", fl, strip(lines[fl]))
	}

	lines, fl = RenderDetailLines(q, Runtime{}, 60, DetailFocus{Active: true, Kind: TargetComment, Anchor: bodyAnchor, CommentID: "comment-1"})
	if fl < 0 || !strings.Contains(strip(lines[fl]), "comment-1") {
		t.Fatalf("comment focus landed on line %d (%q), want comment head", fl, strip(lines[fl]))
	}
}

func TestRenderDetailLineSelectionFocusesFullCommentBlock(t *testing.T) {
	bodyAnchor := CommentAnchor{Kind: CommentAnchorBody, ID: "block-1"}
	q := &Quest{
		ID:      "X",
		Title:   "t",
		Summary: "s",
		Status:  StatusActive,
		Body:    []Block{{ID: "block-1", Type: BlockText, Text: "body text"}},
		Comments: []QuestComment{
			{
				ID:        "comment-1",
				Anchor:    bodyAnchor,
				Status:    CommentOpen,
				Body:      "focused comment body wraps across several rendered detail lines for selection coverage",
				CreatedAt: "2026-06-17T00:00:00Z",
			},
			{
				ID:        "comment-2",
				Anchor:    bodyAnchor,
				Status:    CommentOpen,
				Body:      "next comment should stay unselected",
				CreatedAt: "2026-06-17T00:01:00Z",
			},
		},
	}

	lines, selection := RenderDetailLineSelection(q, Runtime{}, 38, DetailFocus{
		Active:    true,
		Kind:      TargetComment,
		Anchor:    bodyAnchor,
		CommentID: "comment-1",
	})
	commentStart := lineContaining(t, lines, "comment-1")
	nextCommentStart := lineContaining(t, lines, "comment-2")
	if selection.Primary != commentStart {
		t.Fatalf("primary selected line = %d, want comment header line %d", selection.Primary, commentStart)
	}
	if nextCommentStart-commentStart < 3 {
		t.Fatalf("test setup did not render a multi-line focused comment:\n%s", strip(strings.Join(lines, "\n")))
	}
	for line := commentStart; line < nextCommentStart; line++ {
		if !selection.Contains(line) {
			t.Fatalf("focused comment rendered line %d was not selected:\n%s", line, strip(strings.Join(lines, "\n")))
		}
	}
	if selection.Contains(nextCommentStart) {
		t.Fatalf("next comment header line %d was selected with focused comment:\n%s", nextCommentStart, strip(strings.Join(lines, "\n")))
	}
}

func TestRenderDetailOverlaysAutoResults(t *testing.T) {
	q := &Quest{ID: "X", Title: "t", Summary: "s", Status: StatusActive,
		Gates: []Gate{
			{Name: "tests", Type: GateAuto, Check: "cmd:make test"},
			{Name: "ci", Type: GateAuto, Check: "cmd:ci"},
			{Name: "build", Type: GateAuto, Check: "cmd:build"},
			{Name: "ui", Type: GateToggle, Checked: true},
		}}
	rt := Runtime{Gates: map[string]string{"tests": "pass", "ci": "fail", "build": "error"}}
	got := strip(RenderDetailFocused(q, rt, 70, DetailFocus{}))
	for glyph, gate := range map[string]string{"✓": "tests", "✗": "ci", "⚠": "build"} {
		if !strings.Contains(got, glyph) {
			t.Errorf("auto gate %q missing its %q result glyph:\n%s", gate, glyph, got)
		}
	}
	// The checked toggle still shows [x]; results never affect toggles.
	if !strings.Contains(got, "[x] ui") {
		t.Errorf("toggle gate lost its checkbox:\n%s", got)
	}
}

func TestRenderDetailAutoGateNotRunShowsDiamond(t *testing.T) {
	q := &Quest{ID: "X", Title: "t", Summary: "s", Status: StatusActive,
		Gates: []Gate{{Name: "tests", Type: GateAuto, Check: "cmd:make test"}}}
	got := strip(RenderDetail(q, Runtime{}, 60)) // no results
	if !strings.Contains(got, glyphGate+"   tests") {
		t.Errorf("un-run auto gate should show ◇:\n%s", got)
	}
}

func TestGateGlyphAndTypeShareTypeColor(t *testing.T) {
	lipgloss.SetColorProfile(termenv.TrueColor)
	t.Cleanup(func() { lipgloss.SetColorProfile(termenv.Ascii) })

	lines := gateLines([]Gate{
		{Name: "tests", Type: GateAuto, Check: "cmd:make test"},
		{Name: "ui", Type: GateToggle},
	}, 80, Runtime{})

	autoMarker := gateTypeStyle(GateAuto).Render("x")
	autoSeq := autoMarker[:strings.Index(autoMarker, "x")]
	if count := strings.Count(lines[0], autoSeq); count < 2 {
		t.Fatalf("auto gate glyph and type should share the auto color, saw %d markers in %q", count, lines[0])
	}

	toggleMarker := gateTypeStyle(GateToggle).Render("x")
	toggleSeq := toggleMarker[:strings.Index(toggleMarker, "x")]
	if count := strings.Count(lines[1], toggleSeq); count < 2 {
		t.Fatalf("toggle gate glyph and type should share the toggle color, saw %d markers in %q", count, lines[1])
	}
}

func TestDetailTargetsIncludeAutoGates(t *testing.T) {
	q := &Quest{Gates: []Gate{
		{Name: "tests", Type: GateAuto, Check: "x"},
		{Name: "ui", Type: GateToggle},
		{Name: "ci", Type: GateAuto, Check: "y"},
	}, Related: []RelatedLink{{Title: "NEXT-1"}}}
	targets := DetailTargets(q)
	if len(targets) != 5 {
		t.Fatalf("DetailTargets = %d, want 5 (quest + 3 gates + related)", len(targets))
	}
	if targets[0].Kind != TargetQuest || targets[0].Anchor.String() != "quest" {
		t.Errorf("first target = %+v, want quest anchor", targets[0])
	}
	for i := 0; i < 3; i++ {
		if targets[i+1].Kind != TargetGate || targets[i+1].Index != i {
			t.Errorf("target %d = %+v, want gate at index %d", i+1, targets[i+1], i)
		}
	}
	if targets[4].Kind != TargetRelated || targets[4].Index != 0 {
		t.Errorf("fifth target = %+v, want related at index 0", targets[4])
	}
}

func TestDetailTargetsIncludeAnchorsAndOpenCommentRows(t *testing.T) {
	q := &Quest{
		Gates:   []Gate{{Name: "review", Type: GateToggle}},
		Related: []RelatedLink{{ID: "rel-1", Title: "TASK-1"}},
		Body:    []Block{{ID: "block-1", Type: BlockText, Text: "body"}},
		Comments: []QuestComment{
			{ID: "comment-quest", Anchor: CommentAnchor{Kind: CommentAnchorQuest}, Status: CommentOpen, Body: "quest note", CreatedAt: "2026-06-17T00:00:00Z"},
			{ID: "comment-gate", Anchor: CommentAnchor{Kind: CommentAnchorGate, ID: "review"}, Status: CommentOpen, Body: "gate note", CreatedAt: "2026-06-17T00:01:00Z"},
			{ID: "comment-related", Anchor: CommentAnchor{Kind: CommentAnchorRelated, ID: "rel-1"}, Status: CommentOpen, Body: "related note", CreatedAt: "2026-06-17T00:02:00Z"},
			{ID: "comment-body", Anchor: CommentAnchor{Kind: CommentAnchorBody, ID: "block-1"}, Status: CommentOpen, Body: "body note", CreatedAt: "2026-06-17T00:03:00Z"},
			{ID: "comment-resolved", Anchor: CommentAnchor{Kind: CommentAnchorQuest}, Status: CommentResolved, Body: "resolved", CreatedAt: "2026-06-17T00:04:00Z"},
		},
	}
	targets := DetailTargets(q)
	kinds := make([]DetailTargetKind, len(targets))
	labels := make([]string, len(targets))
	comments := make([]string, len(targets))
	for i, tgt := range targets {
		kinds[i] = tgt.Kind
		labels[i] = tgt.Anchor.String()
		comments[i] = tgt.CommentID
	}
	wantKinds := []DetailTargetKind{TargetQuest, TargetComment, TargetGate, TargetComment, TargetRelated, TargetComment, TargetBody, TargetComment}
	if !reflect.DeepEqual(kinds, wantKinds) {
		t.Fatalf("target kinds = %#v, want %#v", kinds, wantKinds)
	}
	wantLabels := []string{"quest", "quest", "gate:review", "gate:review", "related:rel-1", "related:rel-1", "block:block-1", "block:block-1"}
	if !reflect.DeepEqual(labels, wantLabels) {
		t.Fatalf("target labels = %#v, want %#v", labels, wantLabels)
	}
	if strings.Contains(strings.Join(comments, ","), "comment-resolved") {
		t.Fatalf("resolved comment should not be a detail target: %#v", comments)
	}
}

func TestDetailTargetsIncludeListItemCommentRows(t *testing.T) {
	q := &Quest{
		Body: []Block{{
			ID:    "steps",
			Type:  BlockList,
			Items: []string{"first", "second"},
		}},
		Comments: []QuestComment{
			{ID: "comment-item", Anchor: CommentAnchor{Kind: CommentAnchorBody, ID: "steps"}.WithItem(1), Status: CommentOpen, Body: "item note", CreatedAt: "2026-06-17T00:00:00Z"},
			{ID: "comment-block", Anchor: CommentAnchor{Kind: CommentAnchorBody, ID: "steps"}, Status: CommentOpen, Body: "block note", CreatedAt: "2026-06-17T00:01:00Z"},
		},
	}
	targets := DetailTargets(q)
	labels := make([]string, len(targets))
	kinds := make([]DetailTargetKind, len(targets))
	comments := make([]string, len(targets))
	for i, tgt := range targets {
		labels[i] = tgt.Anchor.String()
		kinds[i] = tgt.Kind
		comments[i] = tgt.CommentID
	}
	wantKinds := []DetailTargetKind{TargetQuest, TargetListItem, TargetListItem, TargetComment, TargetComment}
	if !reflect.DeepEqual(kinds, wantKinds) {
		t.Fatalf("target kinds = %#v, want %#v", kinds, wantKinds)
	}
	wantLabels := []string{"quest", "block:steps#item:0", "block:steps#item:1", "block:steps#item:1", "block:steps"}
	if !reflect.DeepEqual(labels, wantLabels) {
		t.Fatalf("target labels = %#v, want %#v", labels, wantLabels)
	}
	if comments[3] != "comment-item" || comments[4] != "comment-block" {
		t.Fatalf("comment target ids = %#v", comments)
	}
}

func TestDetailTargetsIncludeBodyBlocksWithoutIDs(t *testing.T) {
	q := &Quest{
		Body: []Block{
			{Type: BlockHeading, Level: 2, Text: "Context"},
			{Type: BlockText, Text: "body text"},
			{Type: BlockList, Items: []string{"first", "second"}},
		},
	}
	targets := DetailTargets(q)
	if len(targets) != 5 {
		t.Fatalf("DetailTargets = %d, want quest + 2 body blocks + 2 list items", len(targets))
	}
	for i, tgt := range targets[1:3] {
		if tgt.Kind != TargetBody || tgt.Index != i {
			t.Fatalf("target %d = %+v, want body index %d", i+1, tgt, i)
		}
		if tgt.Anchor.Kind != "" {
			t.Fatalf("un-IDed body target should not have an anchor before comment creation: %+v", tgt)
		}
	}
	for itemIndex, tgt := range targets[3:] {
		if tgt.Kind != TargetListItem || tgt.Index != 2 || tgt.ItemIndex != itemIndex {
			t.Fatalf("list target %d = %+v, want list block 2 item %d", itemIndex, tgt, itemIndex)
		}
	}
}

func TestWrapText(t *testing.T) {
	got := wrapText("one two three four", 9)
	want := []string{"one two", "three", "four"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("wrapText = %#v, want %#v", got, want)
	}
}

func TestLoopLabelIncludesPhase(t *testing.T) {
	l := LoopRuntime{Iterations: 2, LastVerdict: "fail", Phase: "checking"}
	if got := l.Label(); got != "↻ loop i2 fail · checking" {
		t.Fatalf("label = %q, want phase appended", got)
	}
	// Markers written by older binaries carry no phase; the label is unchanged.
	l.Phase = ""
	if got := l.Label(); got != "↻ loop i2 fail" {
		t.Fatalf("label without phase = %q", got)
	}
}

func TestAgentGlyphsIncludeOpenCode(t *testing.T) {
	if got := agentGlyphPlain("opencode"); got != iconOpenCode {
		t.Fatalf("agentGlyphPlain(opencode) = %q, want %q", got, iconOpenCode)
	}
	if got := strip(agentGlyphStyled("opencode")); got != iconOpenCode {
		t.Fatalf("agentGlyphStyled(opencode) = %q, want %q", got, iconOpenCode)
	}
}

func TestRenderDetailAdventurerActivityLines(t *testing.T) {
	q := &Quest{ID: "Q-1", Title: "t", Summary: "s", Status: StatusActive}
	now := time.Date(2026, 6, 11, 12, 0, 0, 0, time.UTC)
	rt := Runtime{
		Sessions: []string{"qm-a", "qm-b"},
		Adventurers: []Adventurer{
			{ID: "qm-a", Agent: "claude", State: "working", Since: now.Add(-(2*time.Minute + 14*time.Second))},
			{ID: "qm-b", Agent: "codex", State: "blocked", Since: now.Add(-30 * time.Second)},
			{ID: "qm-c", State: "done", Since: now.Add(-time.Hour)},
		},
		ObservedAt: now,
	}
	got := strip(RenderDetail(q, rt, 100))
	for _, want := range []string{
		"⚔ 3 on it:",
		"- 󰛄 qm-a · working 2m14s",
		"-  qm-b · blocked 30s",
		"qm-c", "idle 1h00m",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("adventurer render missing %q:\n%s", want, got)
		}
	}
}

func TestRenderDetailAdventurersFallBackToSessionsLine(t *testing.T) {
	q := &Quest{ID: "Q-1", Title: "t", Summary: "s", Status: StatusActive}
	rt := Runtime{Sessions: []string{"qm-a", "qm-b"}}
	got := strip(RenderDetail(q, rt, 100))
	for _, want := range []string{"⚔ 2 on it:", "- qm-a", "- qm-b"} {
		if !strings.Contains(got, want) {
			t.Fatalf("bare-sessions runtime missing %q:\n%s", want, got)
		}
	}
}

func TestGateLinesShowVerdictAge(t *testing.T) {
	now := time.Date(2026, 6, 11, 12, 0, 0, 0, time.UTC)
	gates := []Gate{
		{Name: "tests", Type: GateAuto, Check: "cmd:make test"},
		{Name: "ui-ok", Type: GateToggle},
	}
	rt := Runtime{
		Gates:      map[string]string{"tests": "pass"},
		GatesAt:    map[string]time.Time{"tests": now.Add(-2 * time.Minute)},
		ObservedAt: now,
	}
	lines := gateLines(gates, 100, rt)
	if !strings.Contains(strip(lines[0]), "2m ago") {
		t.Errorf("auto gate verdict missing its age: %q", strip(lines[0]))
	}
	if strings.Contains(strip(lines[1]), "ago") {
		t.Errorf("toggle gate must not carry a verdict age: %q", strip(lines[1]))
	}

	// Without an observation clock (legacy callers), no age is invented.
	rt.ObservedAt = time.Time{}
	lines = gateLines(gates, 100, rt)
	if strings.Contains(strip(lines[0]), "ago") {
		t.Errorf("age rendered without ObservedAt: %q", strip(lines[0]))
	}
}

func TestAgoLabelBuckets(t *testing.T) {
	cases := []struct {
		d    time.Duration
		want string
	}{
		{2 * time.Second, "just now"},
		{37 * time.Second, "37s ago"},
		{2*time.Minute + 50*time.Second, "2m ago"},
		{3 * time.Hour, "3h ago"},
		{49 * time.Hour, "2d ago"},
	}
	for _, c := range cases {
		if got := agoLabel(c.d); got != c.want {
			t.Errorf("agoLabel(%s) = %q, want %q", c.d, got, c.want)
		}
	}
}
