//go:build linux || darwin

package state

import (
	"os"
	"slices"
	"strings"
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
	if len(second.Types) != 0 || second.Size != "" {
		t.Fatalf("untagged quest = %#v, want empty tags", second)
	}

	quests, err := LoadQuestsAt(root)
	if err != nil {
		t.Fatalf("load quests: %v", err)
	}
	untaggedLoaded := false
	for _, loaded := range quests {
		if loaded.ID == "qst-two" && (len(loaded.Types) != 0 || loaded.Size != "") {
			t.Fatalf("loaded untagged quest = %#v, want empty tags", loaded)
		}
		if loaded.ID == "qst-two" {
			untaggedLoaded = true
		}
	}
	if !untaggedLoaded {
		t.Fatal("loaded untagged quest missing")
	}
	filtered := FilterQuests(quests, "repo-a", "goldens", nil, nil)
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

func TestQuestTagsNormalizeValidateAndRoundTrip(t *testing.T) {
	root := setStateRoot(t)

	quest, err := UpsertQuestAt(root, Quest{
		ID:      "qst-tagged",
		Content: "Tagged quest",
		Types:   []string{"Research", "BUG", "feature"},
		Size:    "m",
	})
	if err != nil {
		t.Fatalf("upsert tagged quest: %v", err)
	}
	wantTypes := []string{"bug", "feature", "research"}
	if !slices.Equal(quest.Types, wantTypes) || quest.Size != "M" {
		t.Fatalf("saved tags = %v / %q, want %v / M", quest.Types, quest.Size, wantTypes)
	}

	loaded, err := LoadQuestsAt(root)
	if err != nil {
		t.Fatalf("load tagged quest: %v", err)
	}
	if len(loaded) != 1 || !slices.Equal(loaded[0].Types, wantTypes) || loaded[0].Size != "M" {
		t.Fatalf("loaded quests = %#v, want normalized tags", loaded)
	}

	for _, tc := range []struct {
		name  string
		types []string
		size  string
		want  string
	}{
		{name: "unknown type", types: []string{"urgent"}, want: "invalid quest type"},
		{name: "duplicate types after normalization", types: []string{"Bug", "bug"}, want: "duplicate quest type"},
		{name: "unknown size", size: "XL", want: "invalid quest size"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, err := UpsertQuestAt(root, Quest{ID: "qst-invalid", Content: "Invalid", Types: tc.types, Size: tc.size})
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("upsert error = %v, want %q", err, tc.want)
			}
		})
	}
}

func TestFilterQuestsByTagsUsesORWithinAndANDAcrossGroups(t *testing.T) {
	quests := []Quest{
		{ID: "qst-bug-s", Content: "Bug small", Types: []string{"bug"}, Size: "S"},
		{ID: "qst-research-s", Content: "Research small", Types: []string{"research"}, Size: "S"},
		{ID: "qst-bug-m", Content: "Bug medium", Types: []string{"bug"}, Size: "M"},
		{ID: "qst-feature-s", Content: "Feature small", Types: []string{"feature"}, Size: "S"},
		{ID: "qst-untagged", Content: "No tags"},
	}
	filtered := FilterQuests(quests, "", "", []string{"bug", "research"}, []string{"S"})
	got := []string{filtered[0].ID, filtered[1].ID}
	if !slices.Equal(got, []string{"qst-bug-s", "qst-research-s"}) {
		t.Fatalf("filtered quest IDs = %v, want bug/research quests of size S", got)
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
	if len(quests[0].Types) != 0 || quests[0].Size != "" {
		t.Fatalf("legacy quest tags = %v / %q, want empty tags", quests[0].Types, quests[0].Size)
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
