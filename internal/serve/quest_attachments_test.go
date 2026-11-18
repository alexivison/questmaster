//go:build linux || darwin

package serve

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/alexivison/questmaster/internal/state"
)

func TestQuestAttachmentMutationsAndSnapshots(t *testing.T) {
	t.Parallel()
	store, err := state.NewStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	server := &Server{Snapshotter: &Snapshotter{store: store}}
	source := filepath.Join(t.TempDir(), "diagram.txt")
	if err := os.WriteFile(source, []byte("diagram"), 0o600); err != nil {
		t.Fatal(err)
	}
	mutate := func(method string, payload map[string]any) state.Quest {
		t.Helper()
		data, err := json.Marshal(payload)
		if err != nil {
			t.Fatal(err)
		}
		result, err := server.mutate(t.Context(), Request{Method: method, Data: data})
		if err != nil {
			t.Fatal(err)
		}
		return result.(state.Quest)
	}
	quest := mutate("quest.add", map[string]any{"content": "Example quest", "attach_paths": []string{source}})
	if len(quest.Attachments) != 1 {
		t.Fatalf("add = %#v", quest)
	}
	attachment := quest.Attachments[0]
	quest = mutate("quest.edit", map[string]any{"quest_id": quest.ID, "content": "Changed"})
	rows := questSnapshots([]state.Quest{quest})
	if len(rows[0].Attachments) != 1 || rows[0].Attachments[0] != attachment {
		t.Fatalf("snapshot lost attachments: %#v", rows)
	}
	quest = mutate("quest.edit", map[string]any{"quest_id": quest.ID, "detach_ids": []string{attachment.ID}, "attach_paths": []string{source}})
	if len(quest.Attachments) != 1 || quest.Attachments[0].ID == attachment.ID {
		t.Fatalf("replace = %#v", quest)
	}
	if _, err := os.Stat(attachment.Path); !os.IsNotExist(err) {
		t.Fatalf("detach left file: %v", err)
	}
	data, err := json.Marshal(map[string]string{"quest_id": quest.ID})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := server.mutate(t.Context(), Request{Method: "quest.delete", Data: data}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(quest.Attachments[0].Path); !os.IsNotExist(err) {
		t.Fatalf("quest deletion left file: %v", err)
	}
}
