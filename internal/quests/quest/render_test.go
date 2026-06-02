package quest

import (
	"flag"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

var update = flag.Bool("update", false, "update golden files")

func strip(s string) string { return ansi.Strip(s) }

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
	q := &Quest{ID: "AEGIS-3", Summary: "Aegis Phase 3 rollout"}
	got := strip(RenderTrackerLine(q, 60))
	want := "⚑ AEGIS-3 · Aegis Phase 3 rollout"
	if got != want {
		t.Errorf("RenderTrackerLine = %q, want %q", got, want)
	}
}

func TestRenderTrackerLineTruncates(t *testing.T) {
	q := &Quest{ID: "AEGIS-3", Summary: strings.Repeat("x", 200)}
	got := strip(RenderTrackerLine(q, 30))
	if w := ansi.StringWidth(got); w > 30 {
		t.Errorf("RenderTrackerLine width = %d, want <= 30 (%q)", w, got)
	}
	if !strings.HasPrefix(got, "⚑ AEGIS-3 · ") {
		t.Errorf("RenderTrackerLine lost its prefix: %q", got)
	}
}

func TestRenderListRowTags(t *testing.T) {
	cases := []struct {
		name     string
		status   Status
		attached bool
		wantTag  string
	}{
		{"active-on", StatusActive, true, "⚔"},
		{"active-wait", StatusActive, false, "wait"},
		{"wip", StatusWIP, false, "wip"},
		{"done", StatusDone, false, "done"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			q := &Quest{ID: "AEGIS-3", Title: "t", Summary: "Aegis Phase 3 rollout", Status: c.status}
			rt := Runtime{}
			if c.attached {
				rt.Sessions = []string{"qm-1"}
			}
			got := strip(RenderListRow(q, rt, 60))
			if !strings.HasPrefix(got, "AEGIS-3  ") {
				t.Errorf("row lost its id prefix: %q", got)
			}
			if !strings.HasSuffix(got, c.wantTag) {
				t.Errorf("row %q does not end with tag %q", got, c.wantTag)
			}
			if !strings.Contains(got, "Aegis Phase 3 rollout") {
				t.Errorf("row %q lost the goal", got)
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

func TestRenderDetailFocusMarker(t *testing.T) {
	q := &Quest{ID: "X", Title: "t", Summary: "s", Status: StatusActive,
		Gates: []Gate{{Name: "ui-ok", Type: GateToggle}}}
	// Focus the first (only) toggle gate.
	got := strip(RenderDetailFocused(q, Runtime{}, 60, DetailFocus{Active: true, Kind: TargetGate, Index: 0}))
	if !strings.Contains(got, "▸ [ ] ui-ok") {
		t.Errorf("focused gate line missing the ▸ marker:\n%s", got)
	}
}

func TestDetailTargetsSkipAutoGates(t *testing.T) {
	q := &Quest{Gates: []Gate{
		{Name: "tests", Type: GateAuto, Check: "x"},
		{Name: "ui", Type: GateToggle},
		{Name: "ci", Type: GateAuto, Check: "y"},
	}, Related: []RelatedLink{{Title: "NEXT-1"}}}
	targets := DetailTargets(q)
	// only the toggle gate (index 1) + the one related entry.
	if len(targets) != 2 {
		t.Fatalf("DetailTargets = %d, want 2 (toggle + related)", len(targets))
	}
	if targets[0].Kind != TargetGate || targets[0].Index != 1 {
		t.Errorf("first target = %+v, want gate at index 1", targets[0])
	}
	if targets[1].Kind != TargetRelated || targets[1].Index != 0 {
		t.Errorf("second target = %+v, want related at index 0", targets[1])
	}
}

func TestWrapText(t *testing.T) {
	got := wrapText("one two three four", 9)
	want := []string{"one two", "three", "four"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("wrapText = %#v, want %#v", got, want)
	}
}
