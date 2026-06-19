//go:build linux || darwin

package cmd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/alexivison/questmaster/internal/quests/quest"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/workspace"
)

func TestItemCLIAndQuestAttachDetachRoundTrip(t *testing.T) {
	store := setupStore(t)
	t.Setenv(state.StateRootEnv, store.Root())
	t.Setenv(quest.HomeEnv, t.TempDir())
	seedQuest(t, "Q-1", quest.StatusActive, "one")
	seedQuest(t, "Q-2", quest.StatusActive, "two")

	docPath := filepath.Join(t.TempDir(), "plan.html")
	if err := os.WriteFile(docPath, []byte("<h1>Plan</h1>"), 0o644); err != nil {
		t.Fatalf("write doc: %v", err)
	}

	out := runCmd(t, store, sessionsRunner(), "item", "create", "--type", "html", "--title", "Plan", "--path", docPath)
	var created workspace.Item
	if err := json.Unmarshal([]byte(out), &created); err != nil {
		t.Fatalf("item create output is not JSON: %v\n%s", err, out)
	}
	if created.ID == "" || created.Type != "html" || created.Title != "Plan" || created.Artifact.Path != docPath {
		t.Fatalf("created item mismatch: %#v", created)
	}

	runCmd(t, store, sessionsRunner(), "quest", "attach", "Q-1", created.ID)
	runCmd(t, store, sessionsRunner(), "quest", "attach", "Q-1", created.ID)
	runCmd(t, store, sessionsRunner(), "quest", "attach", "Q-2", created.ID)

	q1, err := quest.DefaultStore().Load("Q-1")
	if err != nil {
		t.Fatalf("load Q-1: %v", err)
	}
	q2, err := quest.DefaultStore().Load("Q-2")
	if err != nil {
		t.Fatalf("load Q-2: %v", err)
	}
	if len(q1.Attachments) != 1 || q1.Attachments[0].ItemID != created.ID {
		t.Fatalf("Q-1 attachments = %#v, want exactly one ref", q1.Attachments)
	}
	if len(q2.Attachments) != 1 || q2.Attachments[0].ItemID != created.ID {
		t.Fatalf("Q-2 attachments = %#v, want same item ref", q2.Attachments)
	}

	out = runCmd(t, store, sessionsRunner(), "item", "ls")
	var listed struct {
		Items []workspace.ListedItem `json:"items"`
	}
	if err := json.Unmarshal([]byte(out), &listed); err != nil {
		t.Fatalf("item ls output is not JSON: %v\n%s", err, out)
	}
	if len(listed.Items) != 1 || listed.Items[0].Loose || listed.Items[0].AttachmentCount != 2 {
		t.Fatalf("item ls usage = %#v, want non-loose attached twice", listed.Items)
	}

	runCmd(t, store, sessionsRunner(), "quest", "detach", "Q-1", created.ID)
	runCmd(t, store, sessionsRunner(), "quest", "detach", "Q-1", created.ID)

	q1, _ = quest.DefaultStore().Load("Q-1")
	q2, _ = quest.DefaultStore().Load("Q-2")
	if len(q1.Attachments) != 0 {
		t.Fatalf("Q-1 attachments after detach = %#v, want none", q1.Attachments)
	}
	if len(q2.Attachments) != 1 || q2.Attachments[0].ItemID != created.ID {
		t.Fatalf("Q-2 attachments after Q-1 detach = %#v, want untouched", q2.Attachments)
	}
}

func TestViewCommandResolvesTypeAndSurvivesServeDown(t *testing.T) {
	store := setupStore(t)
	t.Setenv(state.StateRootEnv, store.Root())
	docPath := filepath.Join(t.TempDir(), "doc.html")
	if err := os.WriteFile(docPath, []byte("<h1>Doc</h1>"), 0o644); err != nil {
		t.Fatalf("write doc: %v", err)
	}

	out := runCmd(t, store, sessionsRunner(), "view", docPath)
	var got struct {
		Type  string `json:"type"`
		Title string `json:"title"`
		Path  string `json:"path"`
	}
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("view output is not JSON: %v\n%s", err, out)
	}
	if got.Type != "html" || got.Title != filepath.Base(docPath) || got.Path != docPath {
		t.Fatalf("view output = %#v, want html file payload", got)
	}
}
