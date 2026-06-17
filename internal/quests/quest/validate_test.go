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

func TestValidateRejectsMalformedComments(t *testing.T) {
	base := func() *Quest {
		return &Quest{
			ID:      "X",
			Title:   "t",
			Summary: "s",
			Status:  StatusActive,
			Gates:   []Gate{{Name: "review", Type: GateToggle}},
			Related: []RelatedLink{{ID: "rel-1", Title: "TASK-1"}},
			Body:    []Block{{ID: "body-1", Type: BlockText, Text: "body text"}},
		}
	}
	valid := func() QuestComment {
		return QuestComment{
			ID:        "comment-1",
			Anchor:    CommentAnchor{Kind: CommentAnchorGate, ID: "review"},
			Status:    CommentOpen,
			Body:      "please check this",
			CreatedAt: "2026-06-17T00:00:00Z",
		}
	}

	cases := []struct {
		name    string
		mutate  func(*QuestComment)
		wantSub string
	}{
		{"missing id", func(c *QuestComment) { c.ID = "" }, "missing an id"},
		{"bad status", func(c *QuestComment) { c.Status = "closed" }, `status "closed"`},
		{"missing body", func(c *QuestComment) { c.Body = " \n" }, "missing a body"},
		{"missing created at", func(c *QuestComment) { c.CreatedAt = "" }, "missing created_at"},
		{"quest anchor with id", func(c *QuestComment) {
			c.Anchor = CommentAnchor{Kind: CommentAnchorQuest, ID: "x"}
		}, "quest must not carry an id"},
		{"missing gate", func(c *QuestComment) {
			c.Anchor = CommentAnchor{Kind: CommentAnchorGate, ID: "missing"}
		}, "does not match any gate"},
		{"missing related id", func(c *QuestComment) {
			c.Anchor = CommentAnchor{Kind: CommentAnchorRelated, ID: "missing"}
		}, "related anchors require related[].id"},
		{"missing body id", func(c *QuestComment) {
			c.Anchor = CommentAnchor{Kind: CommentAnchorBody, ID: "missing"}
		}, "block anchors require body[].id"},
		{"unknown anchor kind", func(c *QuestComment) {
			c.Anchor = CommentAnchor{Kind: "line", ID: "1"}
		}, "anchor kind"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			q := base()
			c := valid()
			tc.mutate(&c)
			q.Comments = []QuestComment{c}
			err := Validate(q)
			if err == nil {
				t.Fatalf("Validate accepted malformed comment")
			}
			if !strings.Contains(err.Error(), tc.wantSub) {
				t.Fatalf("Validate error = %q, want substring %q", err.Error(), tc.wantSub)
			}
		})
	}
}

func TestValidateCommentAnchorListItem(t *testing.T) {
	q := &Quest{
		ID:      "X",
		Title:   "t",
		Summary: "s",
		Status:  StatusActive,
		Gates:   []Gate{{Name: "review", Type: GateToggle}},
		Body: []Block{
			{ID: "body-1", Type: BlockText, Text: "body text"},
			{ID: "list-1", Type: BlockList, Items: []string{"first", "second"}},
		},
	}
	if err := ValidateCommentAnchor(q, CommentAnchor{Kind: CommentAnchorBody, ID: "list-1"}.WithItem(1)); err != nil {
		t.Fatalf("ValidateCommentAnchor valid list item: %v", err)
	}
	for _, tc := range []struct {
		name    string
		anchor  CommentAnchor
		wantSub string
	}{
		{
			name:    "non-list block",
			anchor:  CommentAnchor{Kind: CommentAnchorBody, ID: "body-1"}.WithItem(0),
			wantSub: "list block",
		},
		{
			name:    "out of range",
			anchor:  CommentAnchor{Kind: CommentAnchorBody, ID: "list-1"}.WithItem(2),
			wantSub: "out of range",
		},
		{
			name:    "item on gate",
			anchor:  CommentAnchor{Kind: CommentAnchorGate, ID: "review"}.WithItem(0),
			wantSub: "gate must not carry an item",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			err := ValidateCommentAnchor(q, tc.anchor)
			if err == nil {
				t.Fatalf("ValidateCommentAnchor accepted %#v", tc.anchor)
			}
			if !strings.Contains(err.Error(), tc.wantSub) {
				t.Fatalf("ValidateCommentAnchor error = %q, want substring %q", err.Error(), tc.wantSub)
			}
		})
	}
}

func TestValidateRejectsDuplicateStableIDs(t *testing.T) {
	cases := []struct {
		name    string
		quest   *Quest
		wantSub string
	}{
		{
			name: "duplicate comment ids",
			quest: &Quest{
				ID:      "X",
				Title:   "t",
				Summary: "s",
				Status:  StatusActive,
				Comments: []QuestComment{
					{ID: "comment-1", Anchor: CommentAnchor{Kind: CommentAnchorQuest}, Status: CommentOpen, Body: "one", CreatedAt: "2026-06-17T00:00:00Z"},
					{ID: "comment-1", Anchor: CommentAnchor{Kind: CommentAnchorQuest}, Status: CommentOpen, Body: "two", CreatedAt: "2026-06-17T00:00:01Z"},
				},
			},
			wantSub: `duplicate comment id "comment-1"`,
		},
		{
			name: "duplicate related ids",
			quest: &Quest{
				ID:      "X",
				Title:   "t",
				Summary: "s",
				Status:  StatusActive,
				Related: []RelatedLink{
					{ID: "rel-1", Title: "TASK-1"},
					{ID: "rel-1", Title: "TASK-2"},
				},
			},
			wantSub: `duplicate related id "rel-1"`,
		},
		{
			name: "duplicate body ids",
			quest: &Quest{
				ID:      "X",
				Title:   "t",
				Summary: "s",
				Status:  StatusActive,
				Body: []Block{
					{ID: "block-1", Type: BlockText, Text: "one"},
					{ID: "block-1", Type: BlockText, Text: "two"},
				},
			},
			wantSub: `duplicate body id "block-1"`,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := Validate(tc.quest)
			if err == nil {
				t.Fatalf("Validate accepted %s", tc.name)
			}
			if !strings.Contains(err.Error(), tc.wantSub) {
				t.Fatalf("Validate error = %q, want substring %q", err.Error(), tc.wantSub)
			}
		})
	}
}
