package quest

import (
	"strings"
	"testing"
)

func TestUpdateCommentBody(t *testing.T) {
	q := &Quest{Comments: []QuestComment{
		{ID: "comment-1", Body: "old"},
		{ID: "comment-2", Body: "keep"},
	}}

	if err := UpdateCommentBody(q, "comment-1", "  updated\nbody  "); err != nil {
		t.Fatalf("UpdateCommentBody: %v", err)
	}
	if q.Comments[0].Body != "updated\nbody" {
		t.Fatalf("body = %q, want trimmed updated body", q.Comments[0].Body)
	}
	if q.Comments[1].Body != "keep" {
		t.Fatalf("unrelated comment changed: %#v", q.Comments[1])
	}
}

func TestUpdateCommentBodyRejectsEmptyAndMissing(t *testing.T) {
	q := &Quest{Comments: []QuestComment{{ID: "comment-1", Body: "old"}}}
	if err := UpdateCommentBody(q, "comment-1", " \n"); err == nil || !strings.Contains(err.Error(), "body is empty") {
		t.Fatalf("empty update error = %v, want body is empty", err)
	}
	if q.Comments[0].Body != "old" {
		t.Fatalf("empty update changed body to %q", q.Comments[0].Body)
	}
	if err := UpdateCommentBody(q, "missing", "new"); err == nil || !strings.Contains(err.Error(), `comment "missing" not found`) {
		t.Fatalf("missing update error = %v, want not found", err)
	}
}

func TestDeleteComment(t *testing.T) {
	q := &Quest{Comments: []QuestComment{
		{ID: "comment-1", Body: "delete"},
		{ID: "comment-2", Body: "keep"},
	}}

	if err := DeleteComment(q, "comment-1"); err != nil {
		t.Fatalf("DeleteComment: %v", err)
	}
	if len(q.Comments) != 1 || q.Comments[0].ID != "comment-2" {
		t.Fatalf("comments after delete = %#v, want only comment-2", q.Comments)
	}
	if err := DeleteComment(q, "missing"); err == nil || !strings.Contains(err.Error(), `comment "missing" not found`) {
		t.Fatalf("missing delete error = %v, want not found", err)
	}
}
