package quest

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// workedExample is the golden parse target: every frontmatter field, the four
// gate shapes, and one of each body block type, matching quest-format.md.
func workedExample() *Quest {
	return &Quest{
		ID:      "AEGIS-3",
		Title:   "Aegis Phase 3 rollout",
		Status:  StatusActive,
		Summary: "Bring the Phase 3 Aegis layout to the web app, retiring the legacy common-page shell.",
		Date:    "2026-05-28",
		Agent:   "codex",
		Project: "legalon-next",
		Related: []RelatedLink{
			{Type: "linear", Title: "NEXT-1417", URL: "https://linear.app/acme/issue/NEXT-1417"},
			{Type: "linear", Title: "NEXT-1418", URL: "https://linear.app/acme/issue/NEXT-1418"},
			{Type: "github", Title: "PR-1693", URL: "https://github.com/acme/web/pull/1693"},
		},
		Gates: []Gate{
			{Name: "tests", Type: GateAuto, Check: "cmd:make test"},
			{Name: "ci", Type: GateAuto, Check: "github:checks"},
			{Name: "review", Type: GateToggle, Before: BeforePR},
			{Name: "ui-ok", Type: GateToggle},
		},
		Body: []Block{
			{Type: BlockHeading, Level: 2, Text: "Context"},
			{Type: BlockText, Text: "The legacy shell is duplicated per route and drifts. Phase 3 replaces it with the shared Aegis layout and one navigation source."},
			{Type: BlockHeading, Level: 2, Text: "Approach"},
			{Type: BlockList, Ordered: true, Items: []string{
				"Land the layout behind the existing flag",
				"Migrate routes in batches",
				"Keep visual parity until cutover",
			}},
			{Type: BlockRich, Format: "mermaid", Fallback: "diagram: route migration order", Content: "graph LR; legacy --> shared --> cutover"},
			{Type: BlockHeading, Level: 2, Text: "Risk"},
			{Type: BlockRich, Format: "table", Fallback: "table: 5-row phase risk matrix", Content: "<table><tr><td>row</td></tr></table>"},
			{Type: BlockCode, Lang: "ts", Text: "flag.enable('aegis-phase-3')"},
		},
	}
}

func TestParseGoldenWorkedExample(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("testdata", "aegis-3.html"))
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

// TestMarshalParseRoundTrip asserts the canonical JSON round-trips through
// Marshal → ParseJSON unchanged, which is the contract the build/edit flows
// rely on.
func TestMarshalParseRoundTrip(t *testing.T) {
	want := workedExample()
	data, err := Marshal(want)
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}
	got, err := ParseJSON(data)
	if err != nil {
		t.Fatalf("ParseJSON: %v", err)
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("round-trip mismatch:\n got %#v\nwant %#v", got, want)
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
