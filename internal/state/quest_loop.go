//go:build linux || darwin

package state

import (
	"errors"
	"time"
)

// ErrQuestLoopArmed means a session already carries an advisory loop marker.
var ErrQuestLoopArmed = errors.New("quest loop already armed")

// Quest-loop marker owners. The foreground `qm quest loop` process and the
// serve supervisor both arm markers; the owner lets the supervisor refuse to
// run a second loop for a foreground-owned marker.
const (
	QuestLoopOwnerForeground = "foreground"
	QuestLoopOwnerSupervisor = "supervisor"
)

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

	// Terminal phases: the loop has stopped. The supervisor leaves a terminal
	// marker in place (rather than clearing it) so it does not immediately
	// restart a loop that already settled; a re-arm or session end resets it.
	QuestLoopPhaseGreen         = "green"
	QuestLoopPhaseStopped       = "stopped"
	QuestLoopPhaseMisconfigured = "misconfigured"
	QuestLoopPhaseError         = "error"
	QuestLoopPhaseDisarmed      = "disarmed"
)

// IsQuestLoopTerminalPhase reports whether a marker phase means the loop has
// settled and the supervisor should not auto-restart it.
func IsQuestLoopTerminalPhase(phase string) bool {
	switch phase {
	case QuestLoopPhaseGreen, QuestLoopPhaseStopped, QuestLoopPhaseMisconfigured, QuestLoopPhaseError, QuestLoopPhaseDisarmed:
		return true
	default:
		return false
	}
}

// ArmQuestLoop sets the advisory marker for an armed loop owned by owner
// (QuestLoopOwnerForeground or QuestLoopOwnerSupervisor). With force=true, an
// existing marker is replaced. A fresh marker starts in the waiting phase (the
// loop arms, then watches for a done-edge).
func ArmQuestLoop(sessionID string, since time.Time, force bool, owner string) error {
	var armed bool
	err := UpdateSessionState(sessionID, func(ss *SessionState) bool {
		if ss.QuestLoop != nil && !force {
			armed = true
			return false
		}
		ss.QuestLoop = &QuestLoopState{Since: since.UTC(), Phase: QuestLoopPhaseWaiting, Owner: owner}
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

// SetQuestLoopSuppressed records whether a session opts out of the supervisor's
// auto-armed loop. Advisory; it does not affect the foreground command.
func SetQuestLoopSuppressed(sessionID string, suppressed bool) error {
	return UpdateSessionState(sessionID, func(ss *SessionState) bool {
		if ss.QuestLoopSuppressed == suppressed {
			return false
		}
		ss.QuestLoopSuppressed = suppressed
		return true
	})
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
