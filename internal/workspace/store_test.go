//go:build linux || darwin

package workspace

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/alexivison/questmaster/internal/quests/quest"
)

func TestStoreCreatesListsAndGetsItems(t *testing.T) {
	root := t.TempDir()
	store := NewStore(root)

	docPath := filepath.Join(t.TempDir(), "plan.html")
	if err := os.WriteFile(docPath, []byte("<h1>Plan</h1>"), 0o644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}

	item, err := store.Create(CreateInput{
		Type:  "html",
		Title: "Implementation plan",
		Artifact: Artifact{
			Path: docPath,
		},
	})
	if err != nil {
		t.Fatalf("create item: %v", err)
	}
	if item.ID == "" || item.CreatedAt == "" {
		t.Fatalf("created item missing id/created_at: %#v", item)
	}
	if item.Type != "html" || item.Title != "Implementation plan" || item.Artifact.Path != docPath {
		t.Fatalf("created item mismatch: %#v", item)
	}
	if _, err := os.Stat(filepath.Join(root, "items", item.ID+".json")); err != nil {
		t.Fatalf("item manifest not written under state root items dir: %v", err)
	}

	loaded, err := store.Get(item.ID)
	if err != nil {
		t.Fatalf("get item: %v", err)
	}
	if loaded.ID != item.ID || loaded.Artifact.Path != docPath {
		t.Fatalf("loaded item mismatch: %#v", loaded)
	}

	items, err := store.List()
	if err != nil {
		t.Fatalf("list items: %v", err)
	}
	if len(items) != 1 || items[0].ID != item.ID {
		t.Fatalf("list items = %#v, want one created item", items)
	}
}

func TestStoreRejectsInvalidArtifacts(t *testing.T) {
	store := NewStore(t.TempDir())

	for name, input := range map[string]CreateInput{
		"missing type":  {Title: "Doc", Artifact: Artifact{Inline: "<p>Doc</p>"}},
		"missing title": {Type: "html", Artifact: Artifact{Inline: "<p>Doc</p>"}},
		"both artifacts": {
			Type:     "html",
			Title:    "Doc",
			Artifact: Artifact{Path: "/tmp/doc.html", Inline: "<p>Doc</p>"},
		},
		"no artifact": {Type: "html", Title: "Doc"},
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := store.Create(input); err == nil {
				t.Fatalf("Create(%#v) succeeded, want error", input)
			}
		})
	}
}

func TestListedItemsDeriveLooseFromQuestAttachments(t *testing.T) {
	items := []Item{
		{ID: "item-attached", Type: "html", Title: "Attached"},
		{ID: "item-loose", Type: "html", Title: "Loose"},
	}
	quests := []quest.Quest{
		{
			ID: "Q-1",
			Attachments: []quest.AttachmentRef{
				{ItemID: "item-attached", Type: "html", Title: "Attached"},
			},
		},
		{
			ID: "Q-2",
			Attachments: []quest.AttachmentRef{
				{ItemID: "item-attached", Type: "html", Title: "Attached"},
			},
		},
	}

	listed := WithAttachmentUsage(items, quests)
	if len(listed) != 2 {
		t.Fatalf("listed = %#v, want two items", listed)
	}
	if listed[0].ID != "item-attached" || listed[0].Loose || listed[0].AttachmentCount != 2 {
		t.Fatalf("attached usage = %#v, want non-loose count 2", listed[0])
	}
	if listed[1].ID != "item-loose" || !listed[1].Loose || listed[1].AttachmentCount != 0 {
		t.Fatalf("loose usage = %#v, want loose count 0", listed[1])
	}
}

func TestInferTypeFromExtensionAndContent(t *testing.T) {
	htmlPath := filepath.Join(t.TempDir(), "doc.HTML")
	if err := os.WriteFile(htmlPath, []byte("<html><body>Doc</body></html>"), 0o644); err != nil {
		t.Fatalf("write html: %v", err)
	}
	noExtPath := filepath.Join(t.TempDir(), "doc")
	if err := os.WriteFile(noExtPath, []byte("<!doctype html><h1>Doc</h1>"), 0o644); err != nil {
		t.Fatalf("write no-ext html: %v", err)
	}

	if got := InferType(htmlPath, ""); got != "html" {
		t.Fatalf("InferType(html path) = %q, want html", got)
	}
	if got := InferType(noExtPath, ""); got != "html" {
		t.Fatalf("InferType(html content) = %q, want html", got)
	}
	if got := InferType("/tmp/readme.md", ""); got != "markdown" {
		t.Fatalf("InferType(markdown) = %q, want markdown", got)
	}
	if got := InferType("/tmp/unknown.blob", ""); got != "blob" {
		t.Fatalf("InferType(unknown ext) = %q, want blob", got)
	}
	if got := InferType("/tmp/doc.html", "custom"); got != "custom" {
		t.Fatalf("InferType(explicit) = %q, want custom", got)
	}
}
