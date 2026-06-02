package cmd

import (
	"bytes"
	"strings"
	"testing"

	"github.com/alexivison/questmaster/internal/quests/quest"
)

// runQuest executes a quest subcommand against a temp QUESTMASTER_HOME, with
// the editor/opener injectable. Returns stdout and any execute error.
func runQuest(t *testing.T, opts []questOption, args ...string) (string, error) {
	t.Helper()
	cmd := newQuestCmd(opts...)
	var out bytes.Buffer
	cmd.SetOut(&out)
	cmd.SetErr(&bytes.Buffer{})
	cmd.SetArgs(args)
	err := cmd.Execute()
	return out.String(), err
}

func TestQuestNewProducesWIP(t *testing.T) {
	home := t.TempDir()
	t.Setenv(quest.HomeEnv, home)

	out, err := runQuest(t, nil, "new", "ENG-1")
	if err != nil {
		t.Fatalf("quest new: %v", err)
	}
	if !strings.Contains(out, "Created wip quest") {
		t.Errorf("unexpected output: %q", out)
	}

	q, err := quest.DefaultStore().Load("ENG-1")
	if err != nil {
		t.Fatalf("load created quest: %v", err)
	}
	if q.Status != quest.StatusWIP {
		t.Errorf("new quest status = %q, want wip", q.Status)
	}
	if err := quest.Validate(q); err != nil {
		t.Errorf("new quest is invalid: %v", err)
	}
}

func TestQuestNewRefusesDuplicate(t *testing.T) {
	t.Setenv(quest.HomeEnv, t.TempDir())
	if _, err := runQuest(t, nil, "new", "ENG-1"); err != nil {
		t.Fatalf("first new: %v", err)
	}
	if _, err := runQuest(t, nil, "new", "ENG-1"); err == nil {
		t.Fatalf("second new on same id should fail")
	}
}

func TestQuestEditRoundTripsAndRebuilds(t *testing.T) {
	t.Setenv(quest.HomeEnv, t.TempDir())
	if _, err := runQuest(t, nil, "new", "ENG-1"); err != nil {
		t.Fatalf("new: %v", err)
	}

	// Editor that rewrites the summary and adds a heading block.
	edit := func(_ string, initial []byte) ([]byte, error) {
		q, err := quest.ParseJSON(initial)
		if err != nil {
			return nil, err
		}
		q.Summary = "Edited objective"
		q.Body = append(q.Body, quest.Block{Type: quest.BlockHeading, Level: 2, Text: "Edited Section"})
		return quest.Marshal(q)
	}

	if _, err := runQuest(t, []questOption{withQuestEditor(edit)}, "edit", "ENG-1"); err != nil {
		t.Fatalf("edit: %v", err)
	}

	q, err := quest.DefaultStore().Load("ENG-1")
	if err != nil {
		t.Fatalf("load after edit: %v", err)
	}
	if q.Summary != "Edited objective" {
		t.Errorf("edit did not persist summary: %q", q.Summary)
	}
	// The rebuilt HTML body must reflect the edited JSON.
	raw, err := quest.Build(q)
	if err != nil {
		t.Fatalf("build: %v", err)
	}
	if !strings.Contains(string(raw), "<h2>Edited Section</h2>") {
		t.Errorf("rebuilt body missing the edited heading")
	}
}

func TestQuestEditRefusesMalformed(t *testing.T) {
	t.Setenv(quest.HomeEnv, t.TempDir())
	if _, err := runQuest(t, nil, "new", "ENG-1"); err != nil {
		t.Fatalf("new: %v", err)
	}

	// Editor that introduces a schema violation (auto gate without a check).
	edit := func(_ string, initial []byte) ([]byte, error) {
		q, _ := quest.ParseJSON(initial)
		q.Gates = append(q.Gates, quest.Gate{Name: "broken", Type: quest.GateAuto})
		return quest.Marshal(q)
	}

	_, err := runQuest(t, []questOption{withQuestEditor(edit)}, "edit", "ENG-1")
	if err == nil {
		t.Fatalf("malformed edit should be refused")
	}
	if !strings.Contains(err.Error(), "auto requires a check") {
		t.Errorf("edit error = %q, want the validator error", err)
	}
}

func TestQuestEditCannotChangeStatus(t *testing.T) {
	t.Setenv(quest.HomeEnv, t.TempDir())
	if _, err := runQuest(t, nil, "new", "ENG-1"); err != nil {
		t.Fatalf("new: %v", err)
	}
	// Editor tries to self-promote to active; edit must preserve wip.
	edit := func(_ string, initial []byte) ([]byte, error) {
		q, _ := quest.ParseJSON(initial)
		q.Status = quest.StatusActive
		return quest.Marshal(q)
	}
	if _, err := runQuest(t, []questOption{withQuestEditor(edit)}, "edit", "ENG-1"); err != nil {
		t.Fatalf("edit: %v", err)
	}
	q, _ := quest.DefaultStore().Load("ENG-1")
	if q.Status != quest.StatusWIP {
		t.Errorf("edit changed status to %q; status is human-only via approve/done", q.Status)
	}
}

func TestQuestViewUsesTerminalRenderer(t *testing.T) {
	t.Setenv(quest.HomeEnv, t.TempDir())
	if _, err := runQuest(t, nil, "new", "ENG-1", "--title", "Auth refresh", "--summary", "Fix the refresh loop"); err != nil {
		t.Fatalf("new: %v", err)
	}
	out, err := runQuest(t, nil, "view", "ENG-1")
	if err != nil {
		t.Fatalf("view: %v", err)
	}
	q, _ := quest.DefaultStore().Load("ENG-1")
	want := quest.RenderDetail(q, quest.Runtime{}, 72)
	if !strings.Contains(out, want) {
		t.Errorf("view output is not the T2 detail render.\n got: %q\nwant contains: %q", out, want)
	}
}

func TestQuestLsGroupsByStatus(t *testing.T) {
	t.Setenv(quest.HomeEnv, t.TempDir())
	// Two wip quests via new; List groups them under Drafts.
	for _, id := range []string{"ENG-1", "ENG-2"} {
		if _, err := runQuest(t, nil, "new", id); err != nil {
			t.Fatalf("new %s: %v", id, err)
		}
	}
	out, err := runQuest(t, nil, "ls")
	if err != nil {
		t.Fatalf("ls: %v", err)
	}
	if !strings.Contains(out, "Drafts (2)") {
		t.Errorf("ls did not group drafts:\n%s", out)
	}
	if !strings.Contains(out, "ENG-1") || !strings.Contains(out, "ENG-2") {
		t.Errorf("ls missing quests:\n%s", out)
	}
}

func TestActiveQuestChoicesExcludesWIPAndDone(t *testing.T) {
	t.Setenv(quest.HomeEnv, t.TempDir())
	s := quest.DefaultStore()
	for _, q := range []*quest.Quest{
		{ID: "ACT-1", Title: "Active one", Summary: "s", Status: quest.StatusActive},
		{ID: "WIP-1", Title: "Draft", Summary: "s", Status: quest.StatusWIP},
		{ID: "DONE-1", Title: "Turned in", Summary: "s", Status: quest.StatusDone},
	} {
		if err := s.Save(q); err != nil {
			t.Fatalf("save %s: %v", q.ID, err)
		}
	}
	choices := activeQuestChoices()
	if len(choices) != 1 || choices[0].ID != "ACT-1" {
		t.Fatalf("activeQuestChoices = %+v, want only ACT-1 (wip/done excluded)", choices)
	}
	if choices[0].Title != "Active one" {
		t.Errorf("choice title = %q, want %q", choices[0].Title, "Active one")
	}
}

func TestQuestStatusMovesBetweenStates(t *testing.T) {
	t.Setenv(quest.HomeEnv, t.TempDir())
	if _, err := runQuest(t, nil, "new", "ENG-1"); err != nil {
		t.Fatalf("new: %v", err)
	}

	steps := []struct {
		cmd  string
		want quest.Status
	}{
		{"approve", quest.StatusActive},
		{"done", quest.StatusDone},
		{"approve", quest.StatusActive}, // done → back to the board
		{"withdraw", quest.StatusWIP},   // active → back to draft
		{"done", quest.StatusDone},      // wip → straight to done
	}
	for _, st := range steps {
		if _, err := runQuest(t, nil, st.cmd, "ENG-1"); err != nil {
			t.Fatalf("%s: %v", st.cmd, err)
		}
		if q, _ := quest.DefaultStore().Load("ENG-1"); q.Status != st.want {
			t.Errorf("after %s, status = %q, want %q", st.cmd, q.Status, st.want)
		}
	}
}

func TestQuestOpenInvokesOpener(t *testing.T) {
	t.Setenv(quest.HomeEnv, t.TempDir())
	if _, err := runQuest(t, nil, "new", "ENG-1"); err != nil {
		t.Fatalf("new: %v", err)
	}
	var opened string
	opener := func(path string) error { opened = path; return nil }
	if _, err := runQuest(t, []questOption{withQuestOpener(opener)}, "open", "ENG-1"); err != nil {
		t.Fatalf("open: %v", err)
	}
	if !strings.HasSuffix(opened, "ENG-1.html") {
		t.Errorf("opener got %q, want a path ending in ENG-1.html", opened)
	}
}
