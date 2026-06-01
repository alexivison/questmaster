package runtime

import (
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func newTestStore(t *testing.T) (*Store, string) {
	t.Helper()
	home := t.TempDir()
	dir := filepath.Join(home, "quests")
	return NewStore(dir), home
}

func TestRuntimeRoundTrip(t *testing.T) {
	s, _ := newTestStore(t)

	rec := &RuntimeRecord{
		QuestID: "ENG-142",
		Status:  StatusInProgress,
		Sessions: []SessionRef{
			{ID: "qm-1", Role: "master", Agent: "claude", State: "working"},
		},
		PR: &PRStatus{Number: 441, URL: "https://x/441", CI: "green", Review: "pending"},
	}
	if err := s.Save(rec); err != nil {
		t.Fatalf("Save: %v", err)
	}

	got, err := s.Load("ENG-142")
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if got.QuestID != rec.QuestID || got.Status != rec.Status {
		t.Errorf("scalar fields not preserved: %+v", got)
	}
	if !reflect.DeepEqual(got.Sessions, rec.Sessions) {
		t.Errorf("sessions not preserved: %#v", got.Sessions)
	}
	if !reflect.DeepEqual(got.PR, rec.PR) {
		t.Errorf("PR not preserved: %#v", got.PR)
	}
	if got.UpdatedAt.IsZero() {
		t.Errorf("Save should stamp UpdatedAt")
	}
	if got.GateResults == nil {
		t.Errorf("GateResults should be non-nil after Load")
	}
}

func TestRuntimeLoadMissingReturnsDraft(t *testing.T) {
	s, _ := newTestStore(t)
	got, err := s.Load("never-run")
	if err != nil {
		t.Fatalf("Load missing: %v", err)
	}
	if got.Status != StatusDraft {
		t.Errorf("missing record status = %q, want %q", got.Status, StatusDraft)
	}
	if got.QuestID != "never-run" {
		t.Errorf("missing record quest id = %q, want never-run", got.QuestID)
	}
}

// TestRuntimePathUnderHomeNotRepo asserts the record lives under the Quests
// home and never in a repo path.
func TestRuntimePathUnderHomeNotRepo(t *testing.T) {
	s, home := newTestStore(t)
	p := s.Path("ENG-142")
	if !strings.HasPrefix(p, home) {
		t.Errorf("runtime path %q not under Quests home %q", p, home)
	}
	if !strings.HasSuffix(p, "ENG-142.runtime.json") {
		t.Errorf("runtime path %q should sit beside the quest as <id>.runtime.json", p)
	}
	for _, repoish := range []string{"/.wt/", "/.git/", "/worktree"} {
		if strings.Contains(p, repoish) {
			t.Errorf("runtime path %q looks like a repo path (%q)", p, repoish)
		}
	}
}
