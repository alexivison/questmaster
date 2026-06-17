package quest

import (
	"bytes"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// workedExample is the golden parse target: every frontmatter field, the four
// gate shapes, and one of each body block type, matching quest-format.md.
func workedExample() *Quest {
	return &Quest{
		ID:      "DEMO-1",
		Title:   "Widget shell refactor",
		Status:  StatusActive,
		Summary: "Bring the shared layout to the web app, retiring the legacy shell.",
		Date:    "2026-05-28",
		Agent:   "codex",
		Project: "example-app",
		Related: []RelatedLink{
			{Type: "linear", Title: "TASK-1", URL: "https://linear.app/acme/issue/TASK-1"},
			{Type: "linear", Title: "TASK-2", URL: "https://linear.app/acme/issue/TASK-2"},
			{Type: "github", Title: "PR-1", URL: "https://github.com/acme/web/pull/1"},
		},
		Gates: []Gate{
			{Name: "tests", Type: GateAuto, Check: "cmd:make test"},
			{Name: "ci", Type: GateAuto, Check: "github:checks"},
			{Name: "review", Type: GateToggle, Before: BeforePR},
			{Name: "ui-ok", Type: GateToggle},
		},
		Body: []Block{
			{Type: BlockHeading, Level: 2, Text: "Context"},
			{Type: BlockText, Text: "The legacy shell is duplicated per route and drifts. Phase 3 replaces it with the shared layout and one navigation source."},
			{Type: BlockHeading, Level: 2, Text: "Approach"},
			{Type: BlockList, Ordered: true, Items: []string{
				"Land the layout behind the existing flag",
				"Migrate routes in batches",
				"Keep visual parity until cutover",
			}},
			{Type: BlockRich, Format: "mermaid", Fallback: "diagram: route migration order", Content: "graph LR; legacy --> shared --> cutover"},
			{Type: BlockHeading, Level: 2, Text: "Risk"},
			{Type: BlockRich, Format: "table", Fallback: "table: 5-row phase risk matrix", Content: "<table><tr><td>row</td></tr></table>"},
			{Type: BlockCode, Lang: "ts", Text: "flag.enable('example-flag')"},
		},
	}
}

func TestParseGoldenWorkedExample(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("testdata", "demo-1.html"))
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	got, err := Parse(raw)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	want := workedExample()
	if !reflect.DeepEqual(got, want) {
		t.Errorf("Parse mismatch:\n got %#v\nwant %#v", got, want)
	}
}

func TestParseNoScriptBlock(t *testing.T) {
	if _, err := Parse([]byte("<html><body>no quest here</body></html>")); err == nil {
		t.Fatalf("Parse accepted HTML with no quest script block, want error")
	}
}

func TestParseMalformedJSON(t *testing.T) {
	raw := []byte(`<script type="application/json" id="quest">{ not json }</script>`)
	if _, err := Parse(raw); err == nil {
		t.Fatalf("Parse accepted malformed JSON, want error")
	}
}

// TestMarshalNeutralizesAuthoredAgent asserts canonical JSON drops the legacy
// authored agent field; runtime session state is the source of display truth.
func TestMarshalNeutralizesAuthoredAgent(t *testing.T) {
	input := workedExample()
	data, err := Marshal(input)
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}
	if string(data) == "" || bytes.Contains(data, []byte(`"agent"`)) {
		t.Fatalf("Marshal should omit authored agent, got:\n%s", data)
	}
	got, err := ParseJSON(data)
	if err != nil {
		t.Fatalf("ParseJSON: %v", err)
	}
	want := *input
	want.Agent = ""
	if !reflect.DeepEqual(got, &want) {
		t.Errorf("canonical round-trip mismatch:\n got %#v\nwant %#v", got, &want)
	}
}

// TestParseRelatedBackCompatString asserts a bare string related entry still
// decodes (into a RelatedLink with just its Title), so older quests parse.
func TestParseRelatedBackCompatString(t *testing.T) {
	q, err := ParseJSON([]byte(`{"id":"X","title":"t","summary":"s","status":"wip","related":["NEXT-1","NEXT-2"]}`))
	if err != nil {
		t.Fatalf("ParseJSON: %v", err)
	}
	if len(q.Related) != 2 || q.Related[0].Title != "NEXT-1" || q.Related[1].Title != "NEXT-2" {
		t.Errorf("string related did not decode into titles: %#v", q.Related)
	}
}

func TestCommentsRoundTripCanonicalJSON(t *testing.T) {
	q := &Quest{
		ID:      "COMMENT-1",
		Title:   "Commented quest",
		Summary: "s",
		Status:  StatusActive,
		Related: []RelatedLink{
			{ID: "rel-1", Type: "linear", Title: "TASK-1"},
		},
		Gates: []Gate{{Name: "review", Type: GateToggle}},
		Body: []Block{
			{ID: "body-1", Type: BlockText, Text: "body text"},
			{ID: "list-1", Type: BlockList, Items: []string{"first", "second"}},
		},
		Comments: []QuestComment{
			{
				ID:        "comment-1",
				Anchor:    CommentAnchor{Kind: CommentAnchorQuest},
				Status:    CommentOpen,
				Author:    "aleksi",
				Body:      "quest-level note",
				CreatedAt: "2026-06-17T00:00:00Z",
			},
			{
				ID:         "comment-2",
				Anchor:     CommentAnchor{Kind: CommentAnchorBody, ID: "body-1"},
				Status:     CommentResolved,
				Body:       "resolved note",
				CreatedAt:  "2026-06-17T00:01:00Z",
				ResolvedAt: "2026-06-17T00:02:00Z",
			},
			{
				ID:        "comment-3",
				Anchor:    CommentAnchor{Kind: CommentAnchorBody, ID: "list-1"}.WithItem(1),
				Status:    CommentOpen,
				Body:      "list item note",
				CreatedAt: "2026-06-17T00:03:00Z",
			},
		},
	}
	if err := Validate(q); err != nil {
		t.Fatalf("Validate: %v", err)
	}
	data, err := Marshal(q)
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}
	for _, want := range []string{`"comments"`, `"id": "rel-1"`, `"item": 1`} {
		if !strings.Contains(string(data), want) {
			t.Fatalf("canonical JSON missing %s:\n%s", want, data)
		}
	}
	got, err := ParseJSON(data)
	if err != nil {
		t.Fatalf("ParseJSON: %v", err)
	}
	if !reflect.DeepEqual(got, q) {
		t.Errorf("comment round-trip mismatch:\n got %#v\nwant %#v", got, q)
	}
}

func TestParseOldQuestWithoutComments(t *testing.T) {
	q, err := ParseJSON([]byte(`{"id":"OLD-1","title":"old","summary":"s","status":"wip","body":[{"type":"text","text":"old shape"}]}`))
	if err != nil {
		t.Fatalf("ParseJSON old quest: %v", err)
	}
	if len(q.Comments) != 0 {
		t.Fatalf("old quest comments = %#v, want empty", q.Comments)
	}
	if err := Validate(q); err != nil {
		t.Fatalf("Validate old quest without comments: %v", err)
	}
}

// TestParseScriptAttributeOrder asserts extraction does not assume a fixed
// attribute order on the script tag.
func TestParseScriptAttributeOrder(t *testing.T) {
	raw := []byte(`<script id="quest" type="application/json">{"id":"X","title":"t","summary":"s","status":"wip"}</script>`)
	q, err := Parse(raw)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if q.ID != "X" || q.Status != StatusWIP {
		t.Errorf("Parse got %#v", q)
	}
}

// TestParseIgnoresShadowingNestedQuestScript guards the canonical-block
// guarantee: a raw rich-html body block can carry its own id="quest" script,
// which appears before Build's canonical block. Extraction must read the LAST
// (canonical) block, not the first (shadowing) one.
func TestParseIgnoresShadowingNestedQuestScript(t *testing.T) {
	q := &Quest{
		ID: "REAL-1", Title: "real", Summary: "s", Status: StatusActive,
		Body: []Block{
			{Type: BlockRich, Format: "html",
				Content: `<script type="application/json" id="quest">{"id":"EVIL","title":"shadow","summary":"x","status":"done"}</script>`},
		},
	}
	built, err := Build(q)
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	got, err := Parse(built)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if got.ID != "REAL-1" {
		t.Errorf("Parse read the shadowing nested script: id = %q, want REAL-1", got.ID)
	}
	if got.Status != StatusActive {
		t.Errorf("Parse status = %q, want active (not the shadow's done)", got.Status)
	}
	if !reflect.DeepEqual(got, q) {
		t.Errorf("Parse(Build(q)) did not round-trip:\n got %#v\nwant %#v", got, q)
	}
}

// TestParseRejectsTrailingJSONValue asserts a second top-level value is refused
// rather than silently truncated to the first — Decoder.More alone would not
// catch this.
func TestParseRejectsTrailingJSONValue(t *testing.T) {
	if _, err := ParseJSON([]byte(`{"id":"X","title":"t","summary":"s","status":"wip"}{"id":"Y"}`)); err == nil {
		t.Fatalf("ParseJSON accepted a trailing second object, want error")
	}
	// Trailing whitespace is not trailing data — it must still parse.
	if _, err := ParseJSON([]byte("{\"id\":\"X\",\"title\":\"t\",\"summary\":\"s\",\"status\":\"wip\"}\n  \n")); err != nil {
		t.Errorf("ParseJSON rejected trailing whitespace: %v", err)
	}
}
