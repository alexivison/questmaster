package quest

import (
	"strings"
	"testing"
)

func TestValidateAcceptsWorkedExample(t *testing.T) {
	if err := Validate(workedExample()); err != nil {
		t.Fatalf("Validate rejected the worked example: %v", err)
	}
}

func TestValidateMinimalQuest(t *testing.T) {
	q := &Quest{ID: "X", Title: "t", Summary: "s", Status: StatusWIP}
	if err := Validate(q); err != nil {
		t.Fatalf("Validate rejected a minimal valid quest: %v", err)
	}
}

func TestValidateAcceptsCheckedOnToggle(t *testing.T) {
	q := &Quest{ID: "X", Title: "t", Summary: "s", Status: StatusActive,
		Gates: []Gate{{Name: "ui-ok", Type: GateToggle, Checked: true}}}
	if err := Validate(q); err != nil {
		t.Fatalf("Validate rejected a checked toggle gate: %v", err)
	}
}

func TestValidateAllowsUnknownBlockType(t *testing.T) {
	q := &Quest{ID: "X", Title: "t", Summary: "s", Status: StatusActive,
		Body: []Block{{Type: "timeline", Fallback: "a timeline"}}}
	if err := Validate(q); err != nil {
		t.Fatalf("Validate rejected an unknown (forward-compat) block type: %v", err)
	}
}

func TestValidateRejectsMalformed(t *testing.T) {
	base := func() *Quest {
		return &Quest{ID: "X", Title: "t", Summary: "s", Status: StatusActive}
	}
	withBody := func(b Block) *Quest { q := base(); q.Body = []Block{b}; return q }
	withGate := func(g Gate) *Quest { q := base(); q.Gates = []Gate{g}; return q }

	cases := []struct {
		name    string
		quest   *Quest
		wantSub string
	}{
		{"missing id", &Quest{Title: "t", Summary: "s", Status: StatusWIP}, `"id" is required`},
		{"missing title", &Quest{ID: "X", Summary: "s", Status: StatusWIP}, `"title" is required`},
		{"missing summary", &Quest{ID: "X", Title: "t", Status: StatusWIP}, `"summary" is required`},
		{"missing status", &Quest{ID: "X", Title: "t", Summary: "s"}, `"status" is required`},
		{"bad status", &Quest{ID: "X", Title: "t", Summary: "s", Status: "shipped"}, `status "shipped"`},

		{"auto without check", withGate(Gate{Name: "ci", Type: GateAuto}), "auto requires a check"},
		{"toggle with check", withGate(Gate{Name: "ui", Type: GateToggle, Check: "cmd:foo"}), "toggle forbids a check"},
		{"unknown gate type", withGate(Gate{Name: "ci", Type: "sometimes", Check: "x"}), "unknown type"},
		{"gate without name", withGate(Gate{Type: GateToggle}), "missing a name"},
		{"bad before", withGate(Gate{Name: "ci", Type: GateAuto, Check: "x", Before: "merge"}), `before "merge"`},
		{"duplicate gate name", &Quest{ID: "X", Title: "t", Summary: "s", Status: StatusActive,
			Gates: []Gate{{Name: "ci", Type: GateToggle}, {Name: "ci", Type: GateToggle}}}, "duplicate gate name"},

		{"block missing type", withBody(Block{Text: "hi"}), "missing a type"},
		{"heading without text", withBody(Block{Type: BlockHeading, Level: 2}), "heading has no text"},
		{"heading bad level", withBody(Block{Type: BlockHeading, Level: 0, Text: "h"}), "level"},
		{"text without text", withBody(Block{Type: BlockText}), "text block has no text"},
		{"list without items", withBody(Block{Type: BlockList}), "list has no items"},
		{"code without text", withBody(Block{Type: BlockCode, Lang: "go"}), "code block has no text"},
		{"rich missing format", withBody(Block{Type: BlockRich, Fallback: "f"}), "missing a format"},
		{"rich bad format", withBody(Block{Type: BlockRich, Format: "video", Fallback: "f"}), `format "video"`},
		{"rich missing fallback", withBody(Block{Type: BlockRich, Format: "mermaid"}), "missing a fallback"},

		{"checked on auto", withGate(Gate{Name: "ci", Type: GateAuto, Check: "x", Checked: true}), "auto results are observed"},
		{"related without title", &Quest{ID: "X", Title: "t", Summary: "s", Status: StatusActive,
			Related: []RelatedLink{{Type: "linear", URL: "https://x"}}}, "related[0] is missing a title"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			err := Validate(c.quest)
			if err == nil {
				t.Fatalf("Validate(%s) = nil, want error", c.name)
			}
			if !strings.Contains(err.Error(), c.wantSub) {
				t.Errorf("Validate(%s) error = %q, want substring %q", c.name, err.Error(), c.wantSub)
			}
		})
	}
}
