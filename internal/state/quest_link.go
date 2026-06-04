//go:build linux || darwin

package state

import (
	"os"
	"sort"
)

// The quest link is a quest_id on SessionState. It is stamped on explicitly
// attached sessions, including workers, cleared on detach, and read back by
// scanning. The renderer consumes the scan as its runtime; the quest file never
// stores attachment.

// StampQuest sets the session's quest_id. The read-modify-write runs inside the
// per-session flock (UpdateSessionState), so it never clobbers a concurrent
// hook write. A session with no state.json yet gets a minimal one — attaching
// is an explicit act.
func StampQuest(sessionID, questID string) error {
	return UpdateSessionState(sessionID, func(ss *SessionState) bool {
		if ss.QuestID == questID {
			return false
		}
		ss.QuestID = questID
		return true
	})
}

// ClearQuest detaches a session from its quest, returning the quest to the
// board. A no-op when the session is already unattached.
func ClearQuest(sessionID string) error {
	return UpdateSessionState(sessionID, func(ss *SessionState) bool {
		if ss.QuestID == "" {
			return false
		}
		ss.QuestID = ""
		return true
	})
}

// QuestIDForSession returns the session's quest_id, or "" when the session is
// free or has no state.
func QuestIDForSession(sessionID string) (string, error) {
	ss, err := LoadSessionState(sessionID)
	if err != nil {
		return "", err
	}
	if ss == nil {
		return "", nil
	}
	return ss.QuestID, nil
}

// SessionsForQuest scans every session's state.json and returns the ids stamped
// with questID, sorted. These are the directly attached sessions; a quest with
// none reads unattached.
func SessionsForQuest(questID string) ([]string, error) {
	if questID == "" {
		return nil, nil
	}
	root := StateRoot()
	if root == "" {
		return nil, nil
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var ids []string
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		id := e.Name()
		if !IsValidSessionID(id) {
			continue
		}
		ss, err := loadSessionStateAt(root, id)
		if err != nil || ss == nil {
			continue
		}
		if ss.QuestID == questID {
			ids = append(ids, id)
		}
	}
	sort.Strings(ids)
	return ids, nil
}

// IsQuestAttached reports whether any session is on the quest.
func IsQuestAttached(questID string) (bool, error) {
	ids, err := SessionsForQuest(questID)
	return len(ids) > 0, err
}
