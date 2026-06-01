package quest

import (
	"reflect"
	"testing"
)

func TestRenderRoundTrips(t *testing.T) {
	q := Quest{
		ID:   "ENG-9",
		Goal: "Fix the <auth> & retry bug",
		Gates: []Gate{
			{Name: "ci", Type: GateAuto, Check: "github:checks"},
			{Name: "review", Type: GateToggle, Before: BeforePR},
		},
		Next:     []string{"step <one>", "step two & three"},
		Context:  []string{"linear:ENG-9", "slack:#auth"},
		Worktree: "webapp/.wt/eng-9",
		Budget:   5,
	}

	htmlBytes, err := Render(q)
	if err != nil {
		t.Fatalf("Render: %v", err)
	}

	doc, err := Parse(htmlBytes)
	if err != nil {
		t.Fatalf("Parse rendered: %v", err)
	}
	if err := Validate(doc.Head); err != nil {
		t.Fatalf("rendered quest failed Validate: %v", err)
	}
	if !reflect.DeepEqual(doc.Head, q) {
		t.Errorf("round-trip mismatch:\n got %#v\nwant %#v", doc.Head, q)
	}
}

func TestRenderRefusesInvalid(t *testing.T) {
	if _, err := Render(Quest{Goal: "no id"}); err == nil {
		t.Errorf("Render should refuse an invalid quest")
	}
}
