package quest

import "fmt"

// Status transitions are the Questmaster's alone. There is no generic
// SetStatus: the only mutators are Approve (wip→active) and MarkDone
// (active→done), each enforcing the source state, so a quest can never skip
// review (wip→done) and the working-inject path has no status-setting API to
// reach for. A quest is born wip via Scaffold; the agent drafts content, the
// human posts and closes.

// Approve moves a wip quest to active. It refuses any other source state.
func Approve(q *Quest) error {
	if q.Status != StatusWIP {
		return fmt.Errorf("cannot approve quest %q: status is %q, want wip", q.ID, q.Status)
	}
	q.Status = StatusActive
	return nil
}

// MarkDone moves an active quest to done. It refuses any other source state, so
// only an approved (active) quest can be turned in.
func MarkDone(q *Quest) error {
	if q.Status != StatusActive {
		return fmt.Errorf("cannot mark quest %q done: status is %q, want active", q.ID, q.Status)
	}
	q.Status = StatusDone
	return nil
}
