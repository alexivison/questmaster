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

func TestQuestAddListEditRemove(t *testing.T) {
	store := setupStore(t)
	t.Setenv(state.StateRootEnv, store.Root())
	workdir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(workdir, ".git"), 0o755); err != nil {
		t.Fatalf("mkdir git dir: %v", err)
	}

	addOut := runCmd(t, store, sessionsRunner(), "quest", "add", "Regenerate serve goldens", "--project", workdir, "--session", "qm-quest", "--type", "Research,bug", "--type", "FEATURE", "--size", "s")
	var added state.Quest
	if err := json.Unmarshal([]byte(addOut), &added); err != nil {
		t.Fatalf("add output is not quest JSON: %v\n%s", err, addOut)
	}
	if added.ID == "" || added.Content != "Regenerate serve goldens" || added.ProjectID == "" || added.SessionID != "qm-quest" {
		t.Fatalf("added quest = %#v", added)
	}
	if strings.Join(added.Types, ",") != "bug,feature,research" || added.Size != "S" {
		t.Fatalf("added tags = %v / %q, want bug,feature,research / S", added.Types, added.Size)
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
	if strings.Join(quests[0].Types, ",") != "bug,feature,research" || quests[0].Size != "S" {
		t.Fatalf("edit without tag flags changed tags: %v / %q", quests[0].Types, quests[0].Size)
	}

	runCmd(t, store, sessionsRunner(), "quest", "rm", added.ID)
	quests, err = state.LoadQuestsAt(store.Root())
	if err != nil {
		t.Fatalf("load after remove: %v", err)
	}
	if len(quests) != 0 {
		t.Fatalf("quests after remove = %#v, want none", quests)
	}
}

func TestQuestEditTagsSetAndClear(t *testing.T) {
	store := setupStore(t)
	t.Setenv(state.StateRootEnv, store.Root())
	quest, err := state.UpsertQuestAt(store.Root(), state.Quest{ID: "qst-edit-tags", Content: "Edit tags"})
	if err != nil {
		t.Fatalf("seed quest: %v", err)
	}

	runCmd(t, store, sessionsRunner(), "quest", "edit", quest.ID, "--type", "research,BUG", "--size", "m")
	quests, err := state.LoadQuestsAt(store.Root())
	if err != nil {
		t.Fatalf("load set tags: %v", err)
	}
	if strings.Join(quests[0].Types, ",") != "bug,research" || quests[0].Size != "M" {
		t.Fatalf("set tags = %v / %q, want bug,research / M", quests[0].Types, quests[0].Size)
	}

	runCmd(t, store, sessionsRunner(), "quest", "edit", quest.ID, "--type", "", "--size", "")
	quests, err = state.LoadQuestsAt(store.Root())
	if err != nil {
		t.Fatalf("load cleared tags: %v", err)
	}
	if len(quests[0].Types) != 0 || quests[0].Size != "" {
		t.Fatalf("cleared tags = %v / %q, want empty", quests[0].Types, quests[0].Size)
	}
}

func TestQuestListTagFilters(t *testing.T) {
	store := setupStore(t)
	t.Setenv(state.StateRootEnv, store.Root())
	for _, quest := range []state.Quest{
		{ID: "qst-bug-s", Content: "Bug small", Types: []string{"bug"}, Size: "S"},
		{ID: "qst-research-s", Content: "Research small", Types: []string{"research"}, Size: "S"},
		{ID: "qst-bug-m", Content: "Bug medium", Types: []string{"bug"}, Size: "M"},
		{ID: "qst-feature-s", Content: "Feature small", Types: []string{"feature"}, Size: "S"},
		{ID: "qst-untagged", Content: "No tags"},
	} {
		if _, err := state.UpsertQuestAt(store.Root(), quest); err != nil {
			t.Fatalf("seed %s: %v", quest.ID, err)
		}
	}

	out, err := runCmdErr(t, store, sessionsRunner(), "quest", "ls", "--type", "BUG", "--type", "research", "--size", "s")
	if err != nil {
		t.Fatalf("list tag-filtered quests: %v", err)
	}
	var listed struct {
		Quests []state.Quest `json:"quests"`
	}
	if err := json.Unmarshal([]byte(out), &listed); err != nil {
		t.Fatalf("list output is not JSON: %v\n%s", err, out)
	}
	ids := make(map[string]bool, len(listed.Quests))
	for _, quest := range listed.Quests {
		ids[quest.ID] = true
	}
	if len(ids) != 2 || !ids["qst-bug-s"] || !ids["qst-research-s"] {
		t.Fatalf("filtered IDs = %v, want bug/research with size S", ids)
	}

	for _, args := range [][]string{{"quest", "ls", "--type", "urgent"}, {"quest", "ls", "--size", "XL"}} {
		if _, err := runCmdErr(t, store, sessionsRunner(), args...); err == nil || !strings.Contains(err.Error(), "invalid quest") {
			t.Fatalf("%v error = %v, want invalid quest tag", args, err)
		}
	}
}

func TestQuestListByIDs(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	projectA := filepath.Join(t.TempDir(), "repo-a")
	projectB := filepath.Join(t.TempDir(), "repo-b")
	for _, project := range []string{projectA, projectB} {
		if err := os.MkdirAll(filepath.Join(project, ".git"), 0o755); err != nil {
			t.Fatalf("mkdir git dir: %v", err)
		}
	}
	projectAID, _, _, err := state.ResolveQuestProject(store.Root(), projectA, true)
	if err != nil {
		t.Fatalf("resolve project A: %v", err)
	}
	projectBID, _, _, err := state.ResolveQuestProject(store.Root(), projectB, true)
	if err != nil {
		t.Fatalf("resolve project B: %v", err)
	}
	for _, quest := range []state.Quest{
		{ID: "-urgent", Content: "Urgent work", ProjectID: projectAID, ProjectPath: projectA, UpdatedAt: "2026-01-01T00:00:00Z"},
		{ID: "qst-a", Content: "Alpha implementation", ProjectID: projectAID, ProjectPath: projectA, UpdatedAt: "2026-01-01T00:00:00Z"},
		{ID: "qst-b", Content: "Beta followup", ProjectID: projectBID, ProjectPath: projectB, UpdatedAt: "2026-01-01T00:00:00Z"},
		{ID: "qst-c", Content: "Alpha docs", ProjectID: projectAID, ProjectPath: projectA, UpdatedAt: "2026-01-01T00:00:00Z"},
	} {
		if _, err := state.UpsertQuestAt(store.Root(), quest); err != nil {
			t.Fatalf("seed quest %q: %v", quest.ID, err)
		}
	}

	tests := []struct {
		name    string
		args    []string
		wantIDs []string
		wantErr string
	}{
		{name: "selected IDs", args: []string{"quest", "ls", "qst-a", "qst-b"}, wantIDs: []string{"qst-a", "qst-b"}},
		{name: "leading dash ID", args: []string{"quest", "ls", "--", "-urgent"}, wantIDs: []string{"-urgent"}},
		{name: "project filter", args: []string{"quest", "ls", "qst-a", "qst-b", "qst-c", "--project", projectA}, wantIDs: []string{"qst-a", "qst-c"}},
		{name: "search filter", args: []string{"quest", "ls", "qst-a", "qst-b", "qst-c", "--search", "beta"}, wantIDs: []string{"qst-b"}},
		{name: "unknown ID", args: []string{"quest", "ls", "qst-missing"}, wantErr: `quest "qst-missing" not found`},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			out, err := runCmdErr(t, store, sessionsRunner(), tt.args...)
			if tt.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), tt.wantErr) {
					t.Fatalf("error = %v, want %q", err, tt.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatalf("quest ls failed: %v", err)
			}
			var listed struct {
				Quests []state.Quest `json:"quests"`
			}
			if err := json.Unmarshal([]byte(out), &listed); err != nil {
				t.Fatalf("list output is not JSON: %v\n%s", err, out)
			}
			ids := make([]string, len(listed.Quests))
			for i, quest := range listed.Quests {
				ids[i] = quest.ID
			}
			if len(ids) != len(tt.wantIDs) || strings.Join(ids, " ") != strings.Join(tt.wantIDs, " ") {
				t.Fatalf("listed IDs = %v, want %v", ids, tt.wantIDs)
			}
		})
	}
}

func TestQuestStartPayloadRequiresSingleProject(t *testing.T) {
	quests := []state.Quest{
		{ID: "qst-one", Content: "First\nline", ProjectID: "repo", ProjectPath: "/tmp/repo"},
		{ID: "-urgent", Content: "Urgent", ProjectID: "repo", ProjectPath: "/tmp/repo"},
		{ID: "qst two", Content: "Second", ProjectID: "repo", ProjectPath: "/tmp/repo"},
		{ID: "qst'three", Content: "Third", ProjectID: "repo", ProjectPath: "/tmp/repo"},
	}
	cwd, prompt, err := questStartPayload(quests)
	if err != nil {
		t.Fatalf("questStartPayload: %v", err)
	}
	if cwd != "/tmp/repo" || prompt != "Quest IDs: qst-one -urgent 'qst two' 'qst'\\''three'\nRead them with: questmaster quest ls -- qst-one -urgent 'qst two' 'qst'\\''three'" {
		t.Fatalf("cwd=%q prompt=%q", cwd, prompt)
	}

	quests[1].ProjectID = "other"
	if _, _, err := questStartPayload(quests); err == nil {
		t.Fatal("questStartPayload mixed projects: got nil error")
	}
}
