package quest

import "fmt"

// Status is the Questmaster's to set — the agent never calls these. Movement
// between the three states is unrestricted so the human can post a draft to the
// board, send a turned-in quest back for more work, or pull anything back to a
// draft at will. SetStatus is the single mutator; Approve / MarkDone / Withdraw
// are named conveniences for the three targets. There is no agent-facing path
// to any of them (the working-inject clause exposes no status API).

// SetStatus moves a quest to any valid human-owned state.
func SetStatus(q *Quest, to Status) error {
	if _, ok := validStatuses[to]; !ok {
		return fmt.Errorf("invalid status %q (want wip, active, or done)", to)
	}
	q.Status = to
	return nil
}

// Approve posts a quest to the board (active), from any state.
func Approve(q *Quest) error { return SetStatus(q, StatusActive) }

// MarkDone turns a quest in (done), from any state.
func MarkDone(q *Quest) error { return SetStatus(q, StatusDone) }

// Withdraw sends a quest back to draft (wip), from any state.
func Withdraw(q *Quest) error { return SetStatus(q, StatusWIP) }
