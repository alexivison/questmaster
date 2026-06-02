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
