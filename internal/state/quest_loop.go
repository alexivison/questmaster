//go:build linux || darwin

package state

import (
	"errors"
	"time"
)

// ErrQuestLoopArmed means a session already carries an advisory loop marker.
var ErrQuestLoopArmed = errors.New("quest loop already armed")

// Quest-loop phases, written into the advisory marker at each transition so
// renderers can show what the armed loop is doing between iterations.
const (
	// QuestLoopPhaseWaiting means the loop is watching for the next done-edge.
	QuestLoopPhaseWaiting = "waiting"
	// QuestLoopPhaseChecking means the loop is running the quest's auto gates.
	QuestLoopPhaseChecking = "checking"
	// QuestLoopPhasePaused means the agent is blocked on human input and the
	// loop is holding rather than injecting.
	QuestLoopPhasePaused = "paused"
)

// ArmQuestLoop sets the advisory marker for an armed foreground loop. With
// force=true, an existing stale marker is replaced. A fresh marker starts in
// the waiting phase (the loop arms, then watches for a done-edge).
func ArmQuestLoop(sessionID string, since time.Time, force bool) error {
	var armed bool
	err := UpdateSessionState(sessionID, func(ss *SessionState) bool {
		if ss.QuestLoop != nil && !force {
			armed = true
			return false
		}
		ss.QuestLoop = &QuestLoopState{Since: since.UTC(), Phase: QuestLoopPhaseWaiting}
		return true
	})
	if err != nil {
		return err
	}
	if armed {
		return ErrQuestLoopArmed
	}
	return nil
}

// UpdateQuestLoop records the latest visible loop progress if a marker is
// present. It is advisory only; a missing marker is a no-op.
func UpdateQuestLoop(sessionID string, iterations int, verdict, phase string) error {
	return UpdateSessionState(sessionID, func(ss *SessionState) bool {
		if ss.QuestLoop == nil {
			return false
		}
		if ss.QuestLoop.Iterations == iterations && ss.QuestLoop.LastVerdict == verdict && ss.QuestLoop.Phase == phase {
			return false
		}
		ss.QuestLoop.Iterations = iterations
		ss.QuestLoop.LastVerdict = verdict
		ss.QuestLoop.Phase = phase
		return true
	})
}

// SetQuestLoopPhase records a phase transition on an armed marker. Advisory
// only; a missing marker is a no-op.
func SetQuestLoopPhase(sessionID, phase string) error {
	return UpdateSessionState(sessionID, func(ss *SessionState) bool {
		if ss.QuestLoop == nil || ss.QuestLoop.Phase == phase {
			return false
		}
		ss.QuestLoop.Phase = phase
		return true
	})
}

// ClearQuestLoop removes the advisory loop marker. It is safe to call even when
// no loop is currently marked.
func ClearQuestLoop(sessionID string) error {
	return UpdateSessionState(sessionID, func(ss *SessionState) bool {
		if ss.QuestLoop == nil {
			return false
		}
		ss.QuestLoop = nil
		return true
	})
}
