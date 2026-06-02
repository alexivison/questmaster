package quest

import "testing"

func TestApproveOnlyFromWIP(t *testing.T) {
	q := &Quest{ID: "X", Title: "t", Summary: "s", Status: StatusWIP}
	if err := Approve(q); err != nil {
		t.Fatalf("Approve(wip): %v", err)
	}
	if q.Status != StatusActive {
		t.Errorf("after Approve, status = %q, want active", q.Status)
	}
	// active is no longer approvable.
	if err := Approve(q); err == nil {
		t.Errorf("Approve(active) should fail")
	}
	done := &Quest{ID: "X", Status: StatusDone}
	if err := Approve(done); err == nil {
		t.Errorf("Approve(done) should fail")
	}
}

func TestMarkDoneOnlyFromActive(t *testing.T) {
	q := &Quest{ID: "X", Title: "t", Summary: "s", Status: StatusActive}
	if err := MarkDone(q); err != nil {
		t.Fatalf("MarkDone(active): %v", err)
	}
	if q.Status != StatusDone {
		t.Errorf("after MarkDone, status = %q, want done", q.Status)
	}
	// wip cannot skip straight to done.
	wip := &Quest{ID: "X", Status: StatusWIP}
	if err := MarkDone(wip); err == nil {
		t.Errorf("MarkDone(wip) should fail — a quest cannot skip review")
	}
}
