//go:build linux || darwin

package state

import (
	"os"
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

	quests, err := LoadQuestsAt(root)
	if err != nil {
		t.Fatalf("load quests: %v", err)
	}
	filtered := FilterQuests(quests, "repo-a", "goldens")
	if len(filtered) != 1 || filtered[0].ID != "qst-one" {
		t.Fatalf("filtered = %#v, want qst-one", filtered)
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

func TestLegacyDoneQuestRemainsVisible(t *testing.T) {
	root := setStateRoot(t)
	if err := os.WriteFile(QuestsRegistryPath(root), []byte(`{"quests":[{"id":"qst-legacy","content":"Legacy quest","done":true}]}`), 0o644); err != nil {
		t.Fatalf("write legacy quests: %v", err)
	}
	quests, err := LoadQuestsAt(root)
	if err != nil {
		t.Fatalf("load legacy quests: %v", err)
	}
	if len(quests) != 1 || quests[0].ID != "qst-legacy" {
		t.Fatalf("legacy quests = %#v, want qst-legacy", quests)
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
