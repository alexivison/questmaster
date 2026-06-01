package quest

import (
	"bytes"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestParseGoldenTemplate(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("testdata", "quest-template-example.html"))
	if err != nil {
		t.Fatalf("read golden: %v", err)
	}

	doc, err := Parse(raw)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}

	want := Quest{
		ID:   "ENG-142",
		Goal: "Refresh tokens without forcing users to re-login",
		Gates: []Gate{
			{Name: "ci", Type: GateAuto, Check: "github:checks"},
			{Name: "pr", Type: GateAuto, Check: "github:review-approved"},
			{Name: "ui-match", Type: GateToggle},
		},
		Next: []string{
			"Rotate on every use",
			"Retry original after refresh",
			"Manual: no re-login on expiry",
		},
		Context:  []string{"linear:ENG-142", "slack:#auth", "notion:RFC-9"},
		Worktree: "webapp/.wt/eng-142",
	}
	if !reflect.DeepEqual(doc.Head, want) {
		t.Errorf("head mismatch:\n got %#v\nwant %#v", doc.Head, want)
	}

	// Body is the raw document, byte-preserved.
	if !bytes.Equal(doc.Body, raw) {
		t.Errorf("Body should preserve the raw document bytes")
	}

	// The golden quest must also satisfy the schema.
	if err := Validate(doc.Head); err != nil {
		t.Errorf("golden quest failed Validate: %v", err)
	}
}

// TestParseShippedTemplate guards that the embedded quest-template.html (the
// scaffold shipped with the tool) always parses and validates.
func TestParseShippedTemplate(t *testing.T) {
	doc, err := Parse(Template())
	if err != nil {
		t.Fatalf("Parse(Template()): %v", err)
	}
	if err := Validate(doc.Head); err != nil {
		t.Fatalf("shipped template failed Validate: %v", err)
	}
}

func TestParseStripsSpansAndUnescapesEntities(t *testing.T) {
	// Head with highlight spans, an entity, and a value wrapped across lines.
	in := []byte(`<html><body>
<pre><code id="quest-head">{
  <span class="jk">"id"</span>: <span class="js">"A&amp;B-1"</span>,
  <span class="jk">"goal"</span>: <span class="js">"line one
        line two"</span>
}</code></pre>
</body></html>`)
	doc, err := Parse(in)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if doc.Head.ID != "A&B-1" {
		t.Errorf("ID = %q, want %q (entity unescaped)", doc.Head.ID, "A&B-1")
	}
	if doc.Head.Goal != "line one line two" {
		t.Errorf("Goal = %q, want %q (in-string newline collapsed)", doc.Head.Goal, "line one line two")
	}
}

func TestParseSingleQuotedID(t *testing.T) {
	in := []byte(`<pre id='quest-head'>{"id":"X-1","goal":"g"}</pre>`)
	doc, err := Parse(in)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if doc.Head.ID != "X-1" {
		t.Errorf("ID = %q, want X-1", doc.Head.ID)
	}
}

func TestParseErrors(t *testing.T) {
	cases := []struct {
		name string
		in   string
	}{
		{"no head element", `<html><body><p>no quest head here</p></body></html>`},
		{"invalid JSON in head", `<code id="quest-head">{ not json }</code>`},
		{"unterminated head element", `<code id="quest-head">{"id":"x","goal":"g"}`},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if _, err := Parse([]byte(c.in)); err == nil {
				t.Errorf("Parse(%q) = nil error, want an error", c.in)
			}
		})
	}
}
