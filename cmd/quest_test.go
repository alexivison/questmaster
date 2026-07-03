//go:build linux || darwin

package cmd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexivison/questmaster/internal/state"
)

func TestQuestAddListEditDoneRemove(t *testing.T) {
	store := setupStore(t)
	t.Setenv(state.StateRootEnv, store.Root())
	workdir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(workdir, ".git"), 0o755); err != nil {
		t.Fatalf("mkdir git dir: %v", err)
	}

	addOut := runCmd(t, store, sessionsRunner(), "quest", "add", "Regenerate serve goldens", "--project", workdir, "--session", "qm-quest")
	var added state.Quest
	if err := json.Unmarshal([]byte(addOut), &added); err != nil {
		t.Fatalf("add output is not quest JSON: %v\n%s", err, addOut)
	}
	if added.ID == "" || added.Content != "Regenerate serve goldens" || added.ProjectID == "" || added.SessionID != "qm-quest" {
		t.Fatalf("added quest = %#v", added)
	}

	listOut := runCmd(t, store, sessionsRunner(), "quest", "ls", "--search", "goldens")
	var listed struct {
		Quests []state.Quest `json:"quests"`
	}
	if err := json.Unmarshal([]byte(listOut), &listed); err != nil {
		t.Fatalf("list output is not JSON: %v\n%s", err, listOut)
	}
	if len(listed.Quests) != 1 || listed.Quests[0].ID != added.ID {
		t.Fatalf("listed quests = %#v, want added quest", listed.Quests)
	}

	runCmd(t, store, sessionsRunner(), "quest", "edit", added.ID, "--content", "Updated body", "--project", "")
	quests, err := state.LoadQuestsAt(store.Root())
	if err != nil {
		t.Fatalf("load quests: %v", err)
	}
	if len(quests) != 1 || quests[0].Content != "Updated body" || quests[0].ProjectID != "" {
		t.Fatalf("edited quests = %#v", quests)
	}

	runCmd(t, store, sessionsRunner(), "quest", "done", added.ID)
	doneOut := runCmd(t, store, sessionsRunner(), "quest", "ls", "--scope", "done")
	if !strings.Contains(doneOut, added.ID) {
		t.Fatalf("done list = %q, want %s", doneOut, added.ID)
	}
	runCmd(t, store, sessionsRunner(), "quest", "reopen", added.ID)
	runCmd(t, store, sessionsRunner(), "quest", "rm", added.ID)
	quests, err = state.LoadQuestsAt(store.Root())
	if err != nil {
		t.Fatalf("load after remove: %v", err)
	}
	if len(quests) != 0 {
		t.Fatalf("quests after remove = %#v, want none", quests)
	}
}

func TestQuestStartPayloadRequiresSingleProject(t *testing.T) {
	quests := []state.Quest{
		{ID: "qst-one", Content: "First\nline", ProjectID: "repo", ProjectPath: "/tmp/repo"},
		{ID: "qst-two", Content: "Second", ProjectID: "repo", ProjectPath: "/tmp/repo"},
	}
	cwd, prompt, err := questStartPayload(quests)
	if err != nil {
		t.Fatalf("questStartPayload: %v", err)
	}
	if cwd != "/tmp/repo" || prompt != "- First\n  line\n- Second" {
		t.Fatalf("cwd=%q prompt=%q", cwd, prompt)
	}

	quests[1].ProjectID = "other"
	if _, _, err := questStartPayload(quests); err == nil {
		t.Fatal("questStartPayload mixed projects: got nil error")
	}
}
