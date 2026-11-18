//go:build linux || darwin

package cmd

import (
	"bytes"
	"encoding/json"
	"image"
	"image/png"
	"os"
	"path/filepath"
	"testing"

	"github.com/alexivison/questmaster/internal/state"
)

func TestQuestAttachmentCommands(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	source := filepath.Join(t.TempDir(), "design, draft.png")
	var encoded bytes.Buffer
	if err := png.Encode(&encoded, image.NewRGBA(image.Rect(0, 0, 2, 2))); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(source, encoded.Bytes(), 0o600); err != nil {
		t.Fatal(err)
	}
	var quest state.Quest
	decode := func(output string) {
		t.Helper()
		quest = state.Quest{}
		if err := json.Unmarshal([]byte(output), &quest); err != nil {
			t.Fatal(err)
		}
	}
	decode(runCmd(t, store, sessionsRunner(), "quest", "add", "Example quest", "--project", "", "--session", "qm-example", "--attach", source))
	if len(quest.Attachments) != 1 || quest.Attachments[0].Name != "design, draft.png" {
		t.Fatalf("add attachments = %#v", quest.Attachments)
	}
	id, first := quest.ID, quest.Attachments[0]
	copied, err := os.ReadFile(first.Path)
	if err != nil || !bytes.Equal(copied, encoded.Bytes()) {
		t.Fatalf("image attachment did not preserve binary content: %v", err)
	}
	decode(runCmd(t, store, sessionsRunner(), "quest", "edit", id, "--content", "Changed"))
	if len(quest.Attachments) != 1 || quest.Attachments[0] != first {
		t.Fatalf("content edit changed attachments: %#v", quest.Attachments)
	}
	decode(runCmd(t, store, sessionsRunner(), "quest", "edit", id, "--detach", first.ID, "--attach", source, "--attach", source))
	if len(quest.Attachments) != 2 {
		t.Fatalf("replacement attachments = %#v", quest.Attachments)
	}
	var listed struct {
		Quests []state.Quest `json:"quests"`
	}
	output := runCmd(t, store, sessionsRunner(), "quest", "ls", "--", id)
	if err := json.Unmarshal([]byte(output), &listed); err != nil || len(listed.Quests) != 1 || len(listed.Quests[0].Attachments) != 2 {
		t.Fatalf("list attachments = %s, %v", output, err)
	}
	if _, err := runCmdErr(t, store, sessionsRunner(), "quest", "edit", id, "--detach", "att-unknown"); err == nil {
		t.Fatal("unknown attachment should be rejected")
	}
	runCmd(t, store, sessionsRunner(), "quest", "rm", id)
	if _, err := os.Stat(source); err != nil {
		t.Fatalf("quest removal touched source: %v", err)
	}
	for _, attachment := range quest.Attachments {
		if _, err := os.Stat(attachment.Path); !os.IsNotExist(err) {
			t.Fatalf("quest removal left attachment: %v", err)
		}
	}
}
