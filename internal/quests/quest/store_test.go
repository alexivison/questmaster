package quest

import (
	"bytes"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func newTestStore(t *testing.T) *FileStore {
	t.Helper()
	home := t.TempDir()
	return NewStore(filepath.Join(home, "quests"))
}

// minimalQuestHTML returns a small valid quest document for the given id.
func minimalQuestHTML(id, goal string) []byte {
	return []byte(`<!DOCTYPE html><html><body>
<main class="plan"><p>` + goal + `</p></main>
<pre><code id="quest-head">{"id":"` + id + `","goal":"` + goal + `"}</code></pre>
</body></html>`)
}

func TestStoreRoundTrip(t *testing.T) {
	s := newTestStore(t)

	doc, err := Parse(Template()) // valid head, rich body
	if err != nil {
		t.Fatalf("parse template: %v", err)
	}
	if err := s.Save(doc); err != nil {
		t.Fatalf("Save: %v", err)
	}

	got, err := s.Load(doc.Head.ID)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if !reflect.DeepEqual(got.Head, doc.Head) {
		t.Errorf("head not preserved:\n got %#v\nwant %#v", got.Head, doc.Head)
	}
	if !bytes.Equal(got.Body, doc.Body) {
		t.Errorf("body not preserved by round-trip")
	}
}

func TestStoreSaveRefusesMalformedHead(t *testing.T) {
	s := newTestStore(t)

	doc, err := Parse(Template())
	if err != nil {
		t.Fatalf("parse template: %v", err)
	}
	// Corrupt the head: an auto gate with no check is schema-invalid.
	doc.Head.Gates = append(doc.Head.Gates, Gate{Name: "broken", Type: GateAuto})

	err = s.Save(doc)
	if err == nil {
		t.Fatalf("Save accepted a malformed head, want refusal")
	}
	if !strings.Contains(err.Error(), "auto requires a check") {
		t.Errorf("Save error = %q, want the validation error", err)
	}
	// Nothing should have been written.
	if _, lerr := s.Load(doc.Head.ID); lerr == nil {
		t.Errorf("a refused quest must not be written to disk")
	}
}

func TestStoreList(t *testing.T) {
	s := newTestStore(t)

	if err := s.Save(&Document{Head: Quest{ID: "ENG-2", Goal: "two"}, Body: minimalQuestHTML("ENG-2", "two")}); err != nil {
		t.Fatalf("save ENG-2: %v", err)
	}
	if err := s.Save(&Document{Head: Quest{ID: "ENG-1", Goal: "one"}, Body: minimalQuestHTML("ENG-1", "one")}); err != nil {
		t.Fatalf("save ENG-1: %v", err)
	}

	heads, err := s.List()
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(heads) != 2 {
		t.Fatalf("List returned %d heads, want 2", len(heads))
	}
	if heads[0].ID != "ENG-1" || heads[1].ID != "ENG-2" {
		t.Errorf("List not sorted by id: %q, %q", heads[0].ID, heads[1].ID)
	}
}

func TestStoreListEmptyMissingDir(t *testing.T) {
	s := newTestStore(t) // dir does not exist yet
	heads, err := s.List()
	if err != nil {
		t.Fatalf("List on missing dir: %v", err)
	}
	if len(heads) != 0 {
		t.Errorf("List on missing dir = %d heads, want 0", len(heads))
	}
}

// TestStorePathUnderHomeNotRepo asserts Path(id) is under the store dir (which
// lives under the Quests home) and never under a repo/worktree path.
func TestStorePathUnderHomeNotRepo(t *testing.T) {
	home := t.TempDir()
	storeDir := filepath.Join(home, "quests")
	s := NewStore(storeDir)

	p := s.Path("ENG-142")
	if !strings.HasPrefix(p, storeDir) {
		t.Errorf("Path %q not under store dir %q", p, storeDir)
	}
	if !strings.HasPrefix(p, home) {
		t.Errorf("Path %q not under Quests home %q", p, home)
	}
	// A few obvious repo/worktree shapes must never appear in the store path.
	for _, repoish := range []string{"/.wt/", "/worktree", "questmaster/internal", "/.git/"} {
		if strings.Contains(p, repoish) {
			t.Errorf("Path %q looks like it points into a repo (%q)", p, repoish)
		}
	}
}

func TestStoreSaveRefusesUnsafeID(t *testing.T) {
	s := newTestStore(t)
	doc := &Document{
		Head: Quest{ID: "../escape", Goal: "g"},
		Body: minimalQuestHTML("../escape", "g"),
	}
	if err := s.Save(doc); err == nil {
		t.Fatalf("Save accepted an unsafe id, want refusal")
	}
}
