package lifecycle

import (
	"fmt"
	"time"

	"github.com/alexivison/questmaster/internal/quests/quest"
)

// GateToggleResult is returned by human-owned toggle gate mutations.
type GateToggleResult struct {
	QuestID string `json:"quest_id"`
	Gate    string `json:"gate"`
	Checked bool   `json:"checked"`
}

// CommentAddResult is returned by human-owned comment mutations.
type CommentAddResult struct {
	QuestID   string              `json:"quest_id"`
	CommentID string              `json:"comment_id"`
	Anchor    quest.CommentAnchor `json:"anchor"`
	Status    quest.CommentStatus `json:"status"`
	Comment   quest.QuestComment  `json:"comment"`
}

// CommentMutationResult is returned by edit/delete/resolve comment mutations.
type CommentMutationResult struct {
	QuestID   string              `json:"quest_id"`
	CommentID string              `json:"comment_id"`
	Status    quest.CommentStatus `json:"status,omitempty"`
	Comment   quest.QuestComment  `json:"comment,omitempty"`
	Deleted   bool                `json:"deleted,omitempty"`
}

func ToggleGate(store *quest.FileStore, id, gateName string) (GateToggleResult, error) {
	if store == nil {
		store = quest.DefaultStore()
	}
	var checked bool
	q, err := store.Update(id, func(q *quest.Quest) error {
		var err error
		checked, err = quest.ToggleGate(q, gateName)
		return err
	})
	if err != nil {
		return GateToggleResult{}, err
	}
	return GateToggleResult{QuestID: q.ID, Gate: gateName, Checked: checked}, nil
}

func AddComment(store *quest.FileStore, id string, anchor quest.CommentAnchor, author, body string, now time.Time) (CommentAddResult, error) {
	if store == nil {
		store = quest.DefaultStore()
	}
	var comment quest.QuestComment
	q, err := store.Update(id, func(q *quest.Quest) error {
		var err error
		comment, err = quest.AddComment(q, anchor, author, body, now)
		if err != nil {
			return fmt.Errorf("comment add refused: %w", err)
		}
		return nil
	})
	if err != nil {
		return CommentAddResult{}, err
	}
	return CommentAddResult{
		QuestID:   q.ID,
		CommentID: comment.ID,
		Anchor:    comment.Anchor,
		Status:    comment.Status,
		Comment:   comment,
	}, nil
}

func UpdateCommentBody(store *quest.FileStore, id, commentID, body string) (CommentMutationResult, error) {
	if store == nil {
		store = quest.DefaultStore()
	}
	var comment quest.QuestComment
	q, err := store.Update(id, func(q *quest.Quest) error {
		if err := quest.UpdateCommentBody(q, commentID, body); err != nil {
			return fmt.Errorf("comment edit refused: %w", err)
		}
		var ok bool
		comment, ok = quest.CommentByID(q, commentID)
		if !ok {
			return fmt.Errorf("comment %q not found", commentID)
		}
		return nil
	})
	if err != nil {
		return CommentMutationResult{}, err
	}
	return CommentMutationResult{
		QuestID:   q.ID,
		CommentID: comment.ID,
		Status:    comment.Status,
		Comment:   comment,
	}, nil
}

func DeleteComment(store *quest.FileStore, id, commentID string) (CommentMutationResult, error) {
	if store == nil {
		store = quest.DefaultStore()
	}
	q, err := store.Update(id, func(q *quest.Quest) error {
		if err := quest.DeleteComment(q, commentID); err != nil {
			return fmt.Errorf("comment delete refused: %w", err)
		}
		return nil
	})
	if err != nil {
		return CommentMutationResult{}, err
	}
	return CommentMutationResult{QuestID: q.ID, CommentID: commentID, Deleted: true}, nil
}

func ResolveComment(store *quest.FileStore, id, commentID string, now time.Time) (CommentMutationResult, error) {
	if store == nil {
		store = quest.DefaultStore()
	}
	var comment quest.QuestComment
	q, err := store.Update(id, func(q *quest.Quest) error {
		for i := range q.Comments {
			if q.Comments[i].ID != commentID {
				continue
			}
			q.Comments[i].Status = quest.CommentResolved
			q.Comments[i].ResolvedAt = now.UTC().Format(time.RFC3339)
			comment = q.Comments[i]
			return nil
		}
		return fmt.Errorf("comment %q not found on quest %s", commentID, id)
	})
	if err != nil {
		return CommentMutationResult{}, err
	}
	return CommentMutationResult{
		QuestID:   q.ID,
		CommentID: comment.ID,
		Status:    comment.Status,
		Comment:   comment,
	}, nil
}
