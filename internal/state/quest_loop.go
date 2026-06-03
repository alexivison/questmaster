//go:build linux || darwin

package state

import (
	"errors"
	"time"
)

// ErrQuestLoopArmed means a session already carries an advisory loop marker.
var ErrQuestLoopArmed = errors.New("quest loop already armed")

// ArmQuestLoop sets the advisory marker for an armed foreground loop. With
// force=true, an existing stale marker is replaced.
func ArmQuestLoop(sessionID string, since time.Time, force bool) error {
	var armed bool
	err := UpdateSessionState(sessionID, func(ss *SessionState) bool {
		if ss.QuestLoop != nil && !force {
			armed = true
			return false
		}
		ss.QuestLoop = &QuestLoopState{Since: since.UTC()}
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
func UpdateQuestLoop(sessionID string, iterations int, verdict string) error {
	return UpdateSessionState(sessionID, func(ss *SessionState) bool {
		if ss.QuestLoop == nil {
			return false
		}
		if ss.QuestLoop.Iterations == iterations && ss.QuestLoop.LastVerdict == verdict {
			return false
		}
		ss.QuestLoop.Iterations = iterations
		ss.QuestLoop.LastVerdict = verdict
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
