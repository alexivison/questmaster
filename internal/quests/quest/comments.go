package quest

import (
	"fmt"
	"strings"
)

// CommentStatus is the authored lifecycle of an inline quest comment.
type CommentStatus string

const (
	CommentOpen     CommentStatus = "open"
	CommentResolved CommentStatus = "resolved"
)

// CommentAnchorKind names the stable quest element a comment is attached to.
type CommentAnchorKind string

const (
	CommentAnchorQuest   CommentAnchorKind = "quest"
	CommentAnchorGate    CommentAnchorKind = "gate"
	CommentAnchorRelated CommentAnchorKind = "related"
	CommentAnchorBody    CommentAnchorKind = "block"
)

// CommentAnchor points a comment at a stable quest element. Quest anchors carry
// no id; all other anchors use a stable id local to their element kind. Block
// anchors may optionally carry a zero-based list item index.
type CommentAnchor struct {
	Kind CommentAnchorKind `json:"kind"`
	ID   string            `json:"id,omitempty"`
	Item *int              `json:"item,omitempty"`
}

func (a CommentAnchor) String() string {
	base := ""
	if a.Kind == CommentAnchorQuest {
		base = string(a.Kind)
	} else if a.Kind == "" {
		if a.ID == "" {
			base = "(missing)"
		} else {
			base = ":" + a.ID
		}
	} else if a.ID == "" {
		base = string(a.Kind)
	} else {
		base = string(a.Kind) + ":" + a.ID
	}
	if a.Item != nil {
		base += fmt.Sprintf("#item:%d", *a.Item)
	}
	return base
}

// WithItem returns a block anchor narrowed to a zero-based list item index.
func (a CommentAnchor) WithItem(index int) CommentAnchor {
	a.Item = &index
	return a
}

func (a CommentAnchor) equal(b CommentAnchor) bool {
	if a.Kind != b.Kind || a.ID != b.ID {
		return false
	}
	if a.Item == nil || b.Item == nil {
		return a.Item == nil && b.Item == nil
	}
	return *a.Item == *b.Item
}

// QuestComment is a single human-authored note attached to a quest anchor.
type QuestComment struct {
	ID         string        `json:"id"`
	Anchor     CommentAnchor `json:"anchor"`
	Status     CommentStatus `json:"status"`
	Author     string        `json:"author,omitempty"`
	Body       string        `json:"body"`
	CreatedAt  string        `json:"created_at"`
	ResolvedAt string        `json:"resolved_at,omitempty"`
}

const commentIDPrefix = "comment-"

// NewCommentID formats the base id for a generated quest comment.
func NewCommentID(timestamp int64) string {
	return fmt.Sprintf("%s%d", commentIDPrefix, timestamp)
}

// NewCommentIDWithSuffix formats a collision-retry id for a generated comment.
func NewCommentIDWithSuffix(timestamp int64, suffix int) string {
	return fmt.Sprintf("%s%d-%d", commentIDPrefix, timestamp, suffix)
}

// NextCommentID returns a generated comment id that does not collide within q.
func NextCommentID(q *Quest, timestamp int64) string {
	id := NewCommentID(timestamp)
	if !commentIDExists(q, id) {
		return id
	}
	for suffix := 1; ; suffix++ {
		id = NewCommentIDWithSuffix(timestamp, suffix)
		if !commentIDExists(q, id) {
			return id
		}
	}
}

func commentIDExists(q *Quest, id string) bool {
	if q == nil {
		return false
	}
	for _, c := range q.Comments {
		if c.ID == id {
			return true
		}
	}
	return false
}

// CommentByID returns a comment by stable id.
func CommentByID(q *Quest, id string) (QuestComment, bool) {
	if q == nil {
		return QuestComment{}, false
	}
	for _, c := range q.Comments {
		if c.ID == id {
			return c, true
		}
	}
	return QuestComment{}, false
}

// UpdateCommentBody replaces one comment's body text. The lifecycle, anchor,
// author, and timestamps are left unchanged.
func UpdateCommentBody(q *Quest, id, body string) error {
	if q == nil {
		return fmt.Errorf("quest is missing")
	}
	body = strings.TrimSpace(body)
	if body == "" {
		return fmt.Errorf("comment body is empty")
	}
	for i := range q.Comments {
		if q.Comments[i].ID == id {
			q.Comments[i].Body = body
			return nil
		}
	}
	return fmt.Errorf("comment %q not found", id)
}

// DeleteComment removes one comment from active quest data.
func DeleteComment(q *Quest, id string) error {
	if q == nil {
		return fmt.Errorf("quest is missing")
	}
	for i := range q.Comments {
		if q.Comments[i].ID == id {
			q.Comments = append(q.Comments[:i], q.Comments[i+1:]...)
			return nil
		}
	}
	return fmt.Errorf("comment %q not found", id)
}

// OpenComments returns the actionable comments in authored order.
func OpenComments(q *Quest) []QuestComment {
	if q == nil {
		return nil
	}
	var out []QuestComment
	for _, c := range q.Comments {
		if c.Status == CommentOpen {
			out = append(out, c)
		}
	}
	return out
}

// OpenCommentCount returns the number of unresolved comments on a quest.
func OpenCommentCount(q *Quest) int {
	return len(OpenComments(q))
}

func commentsForAnchor(q *Quest, anchor CommentAnchor) []QuestComment {
	if q == nil {
		return nil
	}
	var out []QuestComment
	for _, c := range q.Comments {
		if c.Status == CommentOpen && c.Anchor.equal(anchor) {
			out = append(out, c)
		}
	}
	return out
}
