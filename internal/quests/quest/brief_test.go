package quest

import (
	"strings"
	"testing"
)

func TestWorkingClauseCarriesGoalGatesAndNoSelfCertify(t *testing.T) {
	q := workedExample()
	wc := WorkingClause(q)

	if !strings.Contains(wc, q.Goal()) {
		t.Errorf("working clause missing the goal")
	}
	// Every gate is surfaced as a definition-of-done item.
	for _, g := range q.Gates {
		if !strings.Contains(wc, g.Name) {
			t.Errorf("working clause missing gate %q", g.Name)
		}
	}
	if !strings.Contains(wc, "Definition of done") {
		t.Errorf("working clause missing the definition-of-done heading")
	}
	// The no-self-certify line: the agent cannot mark the quest done.
	if !strings.Contains(wc, "cannot mark this quest done") {
		t.Errorf("working clause missing the no-self-certify line")
	}
	// Re-read instruction.
	if !strings.Contains(wc, "qm quest view "+q.ID) {
		t.Errorf("working clause missing the re-read instruction")
	}
}

func TestWorkingClauseIncludesOnlyOpenComments(t *testing.T) {
	q := &Quest{
		ID:      "COMMENT-1",
		Title:   "Commented",
		Summary: "s",
		Status:  StatusActive,
		Gates:   []Gate{{Name: "review", Type: GateToggle}},
		Comments: []QuestComment{
			{
				ID:        "comment-open",
				Anchor:    CommentAnchor{Kind: CommentAnchorGate, ID: "review"},
				Status:    CommentOpen,
				Author:    "aleksi",
				Body:      "Please tighten the acceptance text.\nSecond line.",
				CreatedAt: "2026-06-17T00:00:00Z",
			},
			{
				ID:        "comment-resolved",
				Anchor:    CommentAnchor{Kind: CommentAnchorQuest},
				Status:    CommentResolved,
				Body:      "This should stay out of the brief.",
				CreatedAt: "2026-06-17T00:00:00Z",
			},
		},
	}
	wc := WorkingClause(q)
	for _, want := range []string{"Open comments", "comment-open", "gate:review", "Please tighten the acceptance text. Second line."} {
		if !strings.Contains(wc, want) {
			t.Fatalf("working clause missing %q:\n%s", want, wc)
		}
	}
	if strings.Contains(wc, "comment-resolved") || strings.Contains(wc, "stay out of the brief") {
		t.Fatalf("working clause should omit resolved comments:\n%s", wc)
	}
}

func TestAuthoringClauseContent(t *testing.T) {
	ac := AuthoringClause()
	for _, want := range []string{
		"questmaster quest new",
		"questmaster quest validate",
		"~/.questmaster/quests",
		"cannot post (approve) or close (mark done)",
	} {
		if !strings.Contains(ac, want) {
			t.Errorf("authoring clause missing %q", want)
		}
	}
}

func TestAuthoringClauseMentionsGeneratedIDs(t *testing.T) {
	ac := AuthoringClause()
	if !strings.Contains(ac, "questmaster quest new") {
		t.Fatalf("authoring clause should name quest creation:\n%s", ac)
	}
	if strings.Contains(ac, "questmaster quest new [id]") || strings.Contains(ac, "questmaster quest new <id>") {
		t.Fatalf("authoring clause should not allow authored quest ids:\n%s", ac)
	}
	if !strings.Contains(ac, "auto-generates") {
		t.Fatalf("authoring clause should mention generated quest ids:\n%s", ac)
	}
	if !strings.Contains(ac, "never invent a slug id yourself") {
		t.Fatalf("authoring clause should tell agents not to invent ids:\n%s", ac)
	}
}

func TestAuthoringClauseMentionsGitHubAutoGates(t *testing.T) {
	ac := AuthoringClause()
	for _, want := range []string{"github:checks", "github:review-approved", "github:pr-merged", ":<pr-number-or-url>", "once a PR exists", "observes a human merge"} {
		if !strings.Contains(ac, want) {
			t.Fatalf("authoring clause missing %q:\n%s", want, ac)
		}
	}
	if strings.Contains(ac, "toggle/human gates for now") {
		t.Fatalf("authoring clause still says GitHub gates are unsupported:\n%s", ac)
	}
}

func TestAuthoringClauseDiscoverRealCommands(t *testing.T) {
	ac := AuthoringClause()
	// The author must fill cmd: checks with the repo's real, discovered command.
	for _, want := range []string{"cmd:", "REAL command", "Makefile", "CI config"} {
		if !strings.Contains(ac, want) {
			t.Errorf("authoring clause missing the discover-real-commands instruction %q", want)
		}
	}
	if strings.Contains(ac, "cmd:make test") {
		t.Fatalf("authoring clause should not suggest make test as a generic command:\n%s", ac)
	}
}
