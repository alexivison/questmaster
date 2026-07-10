//go:build linux || darwin

package state

import (
	"os"
	"strings"
	"testing"
	"time"
)

func TestQuestRegistryCRUD(t *testing.T) {
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

	removed, err := RemoveQuestAt(root, "qst-one")
	if err != nil {
		t.Fatalf("remove: %v", err)
	}
	if !removed {
		t.Fatal("remove returned false, want true")
	}
	quests, err := LoadQuestsAt(root)
	if err != nil {
		t.Fatalf("reload quests: %v", err)
	}
	if len(quests) != 1 || quests[0].ID != "qst-two" {
		t.Fatalf("quests after remove = %#v, want only qst-two", quests)
	}
}

func TestLoadQuestsIgnoresLegacyDoneState(t *testing.T) {
	root := setStateRoot(t)
	if err := os.WriteFile(QuestsRegistryPath(root), []byte(`{"quests":[{"id":"qst-one","content":"Keep this quest","done":true}]}`), 0o644); err != nil {
		t.Fatalf("write legacy registry: %v", err)
	}

	quests, err := LoadQuestsAt(root)
	if err != nil {
		t.Fatalf("load legacy registry: %v", err)
	}
	if len(quests) != 1 || quests[0].ID != "qst-one" {
		t.Fatalf("legacy quest = %#v, want qst-one active", quests)
	}
	if _, err := UpsertQuestAt(root, quests[0]); err != nil {
		t.Fatalf("rewrite legacy quest: %v", err)
	}
	data, err := os.ReadFile(QuestsRegistryPath(root))
	if err != nil {
		t.Fatalf("read rewritten registry: %v", err)
	}
	if strings.Contains(string(data), `"done"`) {
		t.Fatalf("rewritten registry retained done state: %s", data)
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
