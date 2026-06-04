//go:build linux || darwin

package state

import (
	"reflect"
	"testing"
)

func TestStampAndClearQuest(t *testing.T) {
	setStateRoot(t)
	id := "qm-1000"

	if err := StampQuest(id, "DEMO-1"); err != nil {
		t.Fatalf("StampQuest: %v", err)
	}
	got, err := QuestIDForSession(id)
	if err != nil {
		t.Fatalf("QuestIDForSession: %v", err)
	}
	if got != "DEMO-1" {
		t.Errorf("quest_id = %q, want DEMO-1", got)
	}

	if err := ClearQuest(id); err != nil {
		t.Fatalf("ClearQuest: %v", err)
	}
	got, _ = QuestIDForSession(id)
	if got != "" {
		t.Errorf("after ClearQuest, quest_id = %q, want empty", got)
	}
}

func TestStampQuestPreservesPanes(t *testing.T) {
	setStateRoot(t)
	id := "qm-2000"
	if err := InitStartingState(id, map[string]string{"primary": "claude"}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	if err := StampQuest(id, "ENG-1"); err != nil {
		t.Fatalf("StampQuest: %v", err)
	}
	ss, err := LoadSessionState(id)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if ss.QuestID != "ENG-1" {
		t.Errorf("quest_id = %q, want ENG-1", ss.QuestID)
	}
	if _, ok := ss.Panes["primary"]; !ok {
		t.Errorf("stamping a quest dropped the primary pane: %#v", ss.Panes)
	}
}

func TestSessionsForQuestScan(t *testing.T) {
	setStateRoot(t)
	// Two sessions on DEMO-1, one on DEMO-2, one free.
	mustStamp(t, "qm-1", "DEMO-1")
	mustStamp(t, "qm-2", "DEMO-1")
	mustStamp(t, "qm-3", "DEMO-2")
	if err := InitStartingState("qm-4", map[string]string{"primary": "claude"}); err != nil {
		t.Fatalf("seed free session: %v", err)
	}

	got, err := SessionsForQuest("DEMO-1")
	if err != nil {
		t.Fatalf("SessionsForQuest: %v", err)
	}
	want := []string{"qm-1", "qm-2"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("SessionsForQuest(DEMO-1) = %v, want %v", got, want)
	}

	attached, err := IsQuestAttached("DEMO-2")
	if err != nil {
		t.Fatalf("IsQuestAttached: %v", err)
	}
	if !attached {
		t.Errorf("DEMO-2 should read attached")
	}
}

func TestSessionsForQuestIncludesExplicitWorkerStamp(t *testing.T) {
	setStateRoot(t)
	mustStamp(t, "qm-worker", "DEMO-1")

	got, err := SessionsForQuest("DEMO-1")
	if err != nil {
		t.Fatalf("SessionsForQuest: %v", err)
	}
	want := []string{"qm-worker"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("SessionsForQuest(DEMO-1) = %v, want %v", got, want)
	}
	attached, err := IsQuestAttached("DEMO-1")
	if err != nil {
		t.Fatalf("IsQuestAttached: %v", err)
	}
	if !attached {
		t.Fatalf("explicitly stamped worker should count as attached")
	}
}

func TestQuestWithNoSessionReadsUnattached(t *testing.T) {
	setStateRoot(t)
	mustStamp(t, "qm-1", "DEMO-1")

	ids, err := SessionsForQuest("UNUSED-1")
	if err != nil {
		t.Fatalf("SessionsForQuest: %v", err)
	}
	if len(ids) != 0 {
		t.Errorf("SessionsForQuest(unused) = %v, want empty", ids)
	}
	attached, _ := IsQuestAttached("UNUSED-1")
	if attached {
		t.Errorf("an unused quest must read unattached")
	}
}

func mustStamp(t *testing.T, id, questID string) {
	t.Helper()
	if err := StampQuest(id, questID); err != nil {
		t.Fatalf("StampQuest(%s,%s): %v", id, questID, err)
	}
}
