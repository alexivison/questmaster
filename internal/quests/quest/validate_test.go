package quest

import (
	"strings"
	"testing"
)

func TestValidateAcceptsValidQuest(t *testing.T) {
	q := Quest{
		ID:   "ENG-1",
		Goal: "do the thing",
		Gates: []Gate{
			{Name: "ci", Type: GateAuto, Check: "github:checks"},
			{Name: "review", Type: GateToggle, Before: BeforePR},
			{Name: "ui-match", Type: GateToggle},
		},
		Budget: 5,
	}
	if err := Validate(q); err != nil {
		t.Fatalf("Validate rejected a valid quest: %v", err)
	}
}

func TestValidateMinimalQuest(t *testing.T) {
	if err := Validate(Quest{ID: "X", Goal: "g"}); err != nil {
		t.Fatalf("Validate rejected a minimal valid quest: %v", err)
	}
}

func TestValidateRejectsMalformed(t *testing.T) {
	cases := []struct {
		name    string
		quest   Quest
		wantSub string
	}{
		{
			name:    "missing id",
			quest:   Quest{Goal: "g"},
			wantSub: `"id" is required`,
		},
		{
			name:    "missing goal",
			quest:   Quest{ID: "X"},
			wantSub: `"goal" is required`,
		},
		{
			name:    "auto without check",
			quest:   Quest{ID: "X", Goal: "g", Gates: []Gate{{Name: "ci", Type: GateAuto}}},
			wantSub: "auto requires a check",
		},
		{
			name:    "toggle with check",
			quest:   Quest{ID: "X", Goal: "g", Gates: []Gate{{Name: "ui", Type: GateToggle, Check: "cmd:foo"}}},
			wantSub: "toggle forbids a check",
		},
		{
			name:    "unknown gate type",
			quest:   Quest{ID: "X", Goal: "g", Gates: []Gate{{Name: "ci", Type: "sometimes", Check: "x"}}},
			wantSub: "unknown type",
		},
		{
			name:    "gate without name",
			quest:   Quest{ID: "X", Goal: "g", Gates: []Gate{{Type: GateToggle}}},
			wantSub: "missing a name",
		},
		{
			name:    "bad before",
			quest:   Quest{ID: "X", Goal: "g", Gates: []Gate{{Name: "ci", Type: GateAuto, Check: "x", Before: "merge"}}},
			wantSub: `before "merge"`,
		},
		{
			name:    "duplicate gate name",
			quest:   Quest{ID: "X", Goal: "g", Gates: []Gate{{Name: "ci", Type: GateToggle}, {Name: "ci", Type: GateToggle}}},
			wantSub: "duplicate gate name",
		},
		{
			name:    "negative budget",
			quest:   Quest{ID: "X", Goal: "g", Budget: -1},
			wantSub: "budget must not be negative",
		},
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
