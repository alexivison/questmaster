package lifecycle

import (
	"context"

	"github.com/alexivison/questmaster/internal/mergeback"
	"github.com/alexivison/questmaster/internal/quests/quest"
	"github.com/alexivison/questmaster/internal/state"
)

// StatusResult is returned by human-owned quest status transitions.
type StatusResult struct {
	QuestID   string            `json:"quest_id"`
	Status    quest.Status      `json:"status"`
	MergeBack *mergeback.Result `json:"merge_back,omitempty"`
}

// SetStatus persists a quest status transition and runs done side effects.
// Merge-back never turns a successful status write into an error.
func SetStatus(ctx context.Context, questStore *quest.FileStore, sessionStore *state.Store, id string, target quest.Status) (StatusResult, error) {
	if questStore == nil {
		questStore = quest.DefaultStore()
	}
	if sessionStore == nil {
		sessionStore = state.OpenStore(state.StateRoot())
	}
	q, err := questStore.Load(id)
	if err != nil {
		return StatusResult{}, err
	}
	oldStatus := q.Status
	if err := quest.SetStatus(q, target); err != nil {
		return StatusResult{}, err
	}
	if err := questStore.Save(q); err != nil {
		return StatusResult{}, err
	}
	result := StatusResult{QuestID: id, Status: q.Status}
	if target == quest.StatusDone && oldStatus != quest.StatusDone {
		mergeResult := mergeback.ForQuest(ctx, sessionStore, id)
		result.MergeBack = &mergeResult
	}
	return result, nil
}
