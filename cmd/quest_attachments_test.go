//go:build linux || darwin

package cmd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/alexivison/questmaster/internal/state"
)

func TestQuestAttachmentCommands(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	source := filepath.Join(t.TempDir(), "design, draft.txt")
	if err := os.WriteFile(source, []byte("design"), 0o600); err != nil {
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
	if len(quest.Attachments) != 1 || quest.Attachments[0].Name != "design, draft.txt" {
		t.Fatalf("add attachments = %#v", quest.Attachments)
	}
	id, first := quest.ID, quest.Attachments[0]
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
