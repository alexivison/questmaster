//go:build linux || darwin

package state

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func questAttachmentSource(t *testing.T, name, content string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestQuestAttachmentLifecycle(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	source := questAttachmentSource(t, "screen, one.png", "original")
	quest, err := SaveQuestWithAttachmentsAt(root, Quest{Content: "Supporting files"}, []string{source, source}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(quest.Attachments) != 2 || quest.Attachments[0].ID == quest.Attachments[1].ID {
		t.Fatalf("same-name attachments need distinct copies: %#v", quest.Attachments)
	}
	first, second := quest.Attachments[0], quest.Attachments[1]
	if first.Name != filepath.Base(source) || first.Size != 8 || first.Path == source {
		t.Fatalf("attachment metadata = %#v", first)
	}
	if err := os.Remove(source); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(first.Path)
	if err != nil || string(data) != "original" {
		t.Fatalf("stored copy = %q, %v", data, err)
	}
	info, err := os.Stat(first.Path)
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("attachment permissions = %v, %v", info, err)
	}
	// A stale editor cannot discard attachments added since it read the quest.
	stale := quest
	quest, err = SaveQuestWithAttachmentsAt(root, quest, []string{questAttachmentSource(t, "notes.txt", "notes")}, nil)
	if err != nil {
		t.Fatal(err)
	}
	third := quest.Attachments[2]
	stale.ID = " " + stale.ID + " "
	stale.Attachments = nil
	stale.Content = "Edited content"
	quest, err = UpsertQuestAt(root, stale)
	if err != nil || len(quest.Attachments) != 3 {
		t.Fatalf("content edit lost attachments: %#v, %v", quest, err)
	}
	quest, err = SaveQuestWithAttachmentsAt(root, quest, nil, []string{first.ID})
	if err != nil || len(quest.Attachments) != 2 {
		t.Fatalf("detach = %#v, %v", quest, err)
	}
	if _, err := os.Stat(first.Path); !os.IsNotExist(err) {
		t.Fatalf("detached file remains: %v", err)
	}
	loaded, err := LoadQuestsAt(root)
	if err != nil || len(loaded) != 1 || !reflect.DeepEqual(loaded[0], quest) {
		t.Fatalf("round trip = %#v, %v", loaded, err)
	}
	if removed, err := RemoveQuestAt(root, quest.ID); !removed || err != nil {
		t.Fatalf("remove quest = %v, %v", removed, err)
	}
	for _, attachment := range []QuestAttachment{second, third} {
		if _, err := os.Stat(attachment.Path); !os.IsNotExist(err) {
			t.Fatalf("deleted quest's file remains: %v", err)
		}
	}
}

func TestQuestAttachmentFailuresLeaveQuestAndFilesUnchanged(t *testing.T) {
	t.Parallel()
	for _, name := range []string{"missing source", "directory", "oversized", "too many", "unknown detach", "registry write"} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			root := t.TempDir()
			source := questAttachmentSource(t, "notes.txt", "notes")
			quest, err := SaveQuestWithAttachmentsAt(root, Quest{Content: "Original"}, []string{source}, nil)
			if err != nil {
				t.Fatal(err)
			}
			original := quest
			paths := []string{source}
			detach := []string{quest.Attachments[0].ID}
			switch name {
			case "missing source":
				paths = append(paths, source+"-missing") // Roll back the first successful copy too.
			case "directory":
				paths = append(paths, t.TempDir())
			case "oversized":
				large := questAttachmentSource(t, "large.bin", "")
				if err := os.Truncate(large, MaxQuestAttachmentBytes+1); err != nil {
					t.Fatal(err)
				}
				paths = append(paths, large)
			case "too many":
				paths = make([]string, MaxQuestAttachments+1)
			case "unknown detach":
				detach = []string{"att-missing"}
			case "registry write":
				if err := os.Mkdir(QuestsRegistryPath(root)+".tmp", 0o700); err != nil {
					t.Fatal(err)
				}
			}
			quest.Content = "Should not save"
			if _, err := SaveQuestWithAttachmentsAt(root, quest, paths, detach); err == nil {
				t.Fatal("expected attachment save to fail")
			}
			loaded, err := LoadQuestsAt(root)
			if err != nil || len(loaded) != 1 || !reflect.DeepEqual(loaded[0], original) {
				t.Fatalf("failed save changed registry: %#v, %v", loaded, err)
			}
			entries, err := os.ReadDir(filepath.Join(root, "quest-files"))
			if err != nil || len(entries) != 1 || entries[0].Name() != original.Attachments[0].ID {
				t.Fatalf("failed save left extra copies: %v, %v", entries, err)
			}
			if _, err := os.Stat(original.Attachments[0].Path); err != nil {
				t.Fatalf("failed save deleted original attachment: %v", err)
			}
		})
	}
}

func TestQuestAttachmentCleanupStaysInsideLibrary(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	source := questAttachmentSource(t, "keep.txt", "keep")
	removeQuestAttachmentFiles(root, []QuestAttachment{
		{ID: "../../outside", Name: filepath.Base(source), Path: source},
		{ID: "att-00000000000000000000000000000000", Name: filepath.Base(source), Path: source},
	})
	if _, err := os.Stat(source); err != nil {
		t.Fatalf("cleanup touched an external file: %v", err)
	}
}
