//go:build linux || darwin

package state

import (
	"testing"
	"time"
)

func TestQuestRegistryCRUDAndFilter(t *testing.T) {
	root := setStateRoot(t)

	first, err := UpsertQuestAt(root, Quest{
		ID:          "qst-one",
		Content:     "Regenerate serve goldens",
		ProjectID:   "repo-a",
		ProjectPath: "/tmp/repo-a",
		ProjectName: "repo-a",
		SessionID:   "qm-quest",
	})
	if err != nil {
		t.Fatalf("upsert first: %v", err)
	}
	second, err := UpsertQuestAt(root, Quest{
		ID:        "qst-two",
		Content:   "Clean up old notes",
		ProjectID: "repo-b",
	})
	if err != nil {
		t.Fatalf("upsert second: %v", err)
	}
	if first.CreatedAt == "" || first.UpdatedAt == "" || second.CreatedAt == "" {
		t.Fatalf("timestamps missing: first=%#v second=%#v", first, second)
	}

	done, err := SetQuestDoneAt(root, []string{"qst-two"}, true)
	if err != nil {
		t.Fatalf("set done: %v", err)
	}
	if len(done) != 1 || !done[0].Done {
		t.Fatalf("done = %#v, want qst-two done", done)
	}

	quests, err := LoadQuestsAt(root)
	if err != nil {
		t.Fatalf("load quests: %v", err)
	}
	active := FilterQuests(quests, QuestScopeActive, "repo-a", "goldens")
	if len(active) != 1 || active[0].ID != "qst-one" {
		t.Fatalf("active filtered = %#v, want qst-one", active)
	}
	if got := FilterQuests(quests, QuestScopeDone, "", "notes"); len(got) != 1 || got[0].ID != "qst-two" {
		t.Fatalf("done filtered = %#v, want qst-two", got)
	}

	removed, err := RemoveQuestAt(root, "qst-one")
	if err != nil {
		t.Fatalf("remove: %v", err)
	}
	if !removed {
		t.Fatal("remove returned false, want true")
	}
	quests, err = LoadQuestsAt(root)
	if err != nil {
		t.Fatalf("reload quests: %v", err)
	}
	if len(quests) != 1 || quests[0].ID != "qst-two" {
		t.Fatalf("quests after remove = %#v, want only qst-two", quests)
	}
}

func TestQuestIDCollisionSuffix(t *testing.T) {
	got := nextQuestID([]Quest{{ID: "qst-100"}, {ID: "qst-100-2"}}, mustQuestTime(t, "1970-01-01T00:01:40Z"))
	if got != "qst-100-3" {
		t.Fatalf("nextQuestID = %q, want qst-100-3", got)
	}
}

func mustQuestTime(t *testing.T, raw string) time.Time {
	t.Helper()
	got, ok := parseQuestTime(raw)
	if !ok {
		t.Fatalf("parse time %q", raw)
	}
	return got
}
