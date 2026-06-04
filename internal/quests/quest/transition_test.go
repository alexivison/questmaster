package quest

import "testing"

func TestSetStatusMovesFreely(t *testing.T) {
	q := &Quest{ID: "X", Title: "t", Summary: "s", Status: StatusWIP}
	// wip → done (no longer forced through active), → active, → wip.
	for _, to := range []Status{StatusDone, StatusActive, StatusWIP, StatusActive} {
		if err := SetStatus(q, to); err != nil {
			t.Fatalf("SetStatus(%s): %v", to, err)
		}
		if q.Status != to {
			t.Fatalf("status = %q, want %q", q.Status, to)
		}
	}
}

func TestSetStatusRejectsUnknown(t *testing.T) {
	q := &Quest{ID: "X", Status: StatusWIP}
	if err := SetStatus(q, "shipped"); err == nil {
		t.Fatalf("SetStatus accepted an unknown status")
	}
}

func TestNamedTransitionsFromAnyState(t *testing.T) {
	cases := []struct {
		name string
		from Status
		fn   func(*Quest) error
		want Status
	}{
		{"approve from done", StatusDone, Approve, StatusActive},
		{"approve from wip", StatusWIP, Approve, StatusActive},
		{"done from wip", StatusWIP, MarkDone, StatusDone},
		{"withdraw from done", StatusDone, Withdraw, StatusWIP},
		{"withdraw from active", StatusActive, Withdraw, StatusWIP},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			q := &Quest{ID: "X", Status: c.from}
			if err := c.fn(q); err != nil {
				t.Fatalf("%s: %v", c.name, err)
			}
			if q.Status != c.want {
				t.Errorf("%s → %q, want %q", c.name, q.Status, c.want)
			}
		})
	}
}
