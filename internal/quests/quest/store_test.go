package quest

import (
	"os"
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

// writeQuestFile drops a minimal quest HTML (script block only) into the store
// so Load/List can be exercised before the write path (Save) exists.
func writeQuestFile(t *testing.T, s *FileStore, id, title string) {
	t.Helper()
	if err := os.MkdirAll(s.Dir(), 0o755); err != nil {
		t.Fatalf("mkdir store: %v", err)
	}
	html := `<!doctype html><html><body>
<script type="application/json" id="quest">{"id":"` + id + `","title":"` + title + `","summary":"s","status":"wip"}</script>
</body></html>`
	if err := os.WriteFile(s.Path(id), []byte(html), 0o644); err != nil {
		t.Fatalf("write quest %s: %v", id, err)
	}
}

func TestStoreSaveRoundTrip(t *testing.T) {
	s := newTestStore(t)
	want := workedExample()
	if err := s.Save(want); err != nil {
		t.Fatalf("Save: %v", err)
	}
	got, err := s.Load(want.ID)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	expected := *want
	expected.Agent = ""
	if !reflect.DeepEqual(got, &expected) {
		t.Errorf("Save/Load round-trip mismatch:\n got %#v\nwant %#v", got, &expected)
	}
}

func TestStoreSaveNeutralizesAuthoredAgent(t *testing.T) {
	s := newTestStore(t)
	q := &Quest{ID: "ENG-9", Title: "t", Summary: "s", Status: StatusWIP, Agent: "codex"}
	if err := s.Save(q); err != nil {
		t.Fatalf("Save: %v", err)
	}
	got, err := s.Load("ENG-9")
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if got.Agent != "" {
		t.Fatalf("saved quest agent = %q, want empty", got.Agent)
	}
	raw, err := os.ReadFile(s.Path("ENG-9"))
	if err != nil {
		t.Fatalf("read saved quest: %v", err)
	}
	if strings.Contains(string(raw), `"agent"`) {
		t.Fatalf("saved quest should not contain authored agent:\n%s", raw)
	}
}

func TestStoreSaveRefusesMalformed(t *testing.T) {
	s := newTestStore(t)
	q := workedExample()
	q.Gates = append(q.Gates, Gate{Name: "broken", Type: GateAuto}) // auto without check
	err := s.Save(q)
	if err == nil {
		t.Fatalf("Save accepted a malformed quest, want refusal")
	}
	if !strings.Contains(err.Error(), "auto requires a check") {
		t.Errorf("Save error = %q, want the validator error", err)
	}
	if s.Exists(q.ID) {
		t.Errorf("a refused quest must not be written to disk")
	}
}

func TestScaffoldIsValidWIP(t *testing.T) {
	q := Scaffold("ENG-9", "", "", "2026-06-02")
	if q.Status != StatusWIP {
		t.Errorf("Scaffold status = %q, want wip", q.Status)
	}
	if err := Validate(q); err != nil {
		t.Errorf("Scaffold produced an invalid quest: %v", err)
	}
}

func TestScaffoldDefaultsDoNotInventAutoCommands(t *testing.T) {
	q := Scaffold("ENG-9", "", "", "2026-06-02")
	if q.Agent != "" {
		t.Fatalf("Scaffold agent = %q, want empty until runtime attachment", q.Agent)
	}
	for _, g := range q.Gates {
		if g.Check == "cmd:make test" {
			t.Fatalf("Scaffold should not imply make test exists: %+v", q.Gates)
		}
		if g.Type == GateAuto {
			t.Fatalf("Scaffold should not create fake auto gates by default: %+v", q.Gates)
		}
	}
}

func TestStoreLoad(t *testing.T) {
	s := newTestStore(t)
	writeQuestFile(t, s, "ENG-1", "one")

	q, err := s.Load("ENG-1")
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if q.ID != "ENG-1" || q.Title != "one" || q.Status != StatusWIP {
		t.Errorf("Load got %#v", q)
	}
}

func TestStoreListSortedSkipsMalformed(t *testing.T) {
	s := newTestStore(t)
	writeQuestFile(t, s, "ENG-2", "two")
	writeQuestFile(t, s, "ENG-1", "one")
	// A malformed file must not blank the list.
	if err := os.WriteFile(s.Path("BAD"), []byte("<html>no script</html>"), 0o644); err != nil {
		t.Fatalf("write bad: %v", err)
	}

	quests, err := s.List()
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(quests) != 2 {
		t.Fatalf("List returned %d quests, want 2", len(quests))
	}
	if quests[0].ID != "ENG-1" || quests[1].ID != "ENG-2" {
		t.Errorf("List not sorted by id: %q, %q", quests[0].ID, quests[1].ID)
	}
}

func TestStoreListEmptyMissingDir(t *testing.T) {
	s := newTestStore(t)
	quests, err := s.List()
	if err != nil {
		t.Fatalf("List on missing dir: %v", err)
	}
	if len(quests) != 0 {
		t.Errorf("List on missing dir = %d quests, want 0", len(quests))
	}
}

// TestStorePathUnderHomeNotRepo asserts Path(id) lands under the store dir
// (which lives under the questmaster home) and never under a repo/worktree.
func TestStorePathUnderHomeNotRepo(t *testing.T) {
	home := t.TempDir()
	storeDir := filepath.Join(home, "quests")
	s := NewStore(storeDir)

	p := s.Path("ENG-142")
	if !strings.HasPrefix(p, storeDir) {
		t.Errorf("Path %q not under store dir %q", p, storeDir)
	}
	if !strings.HasPrefix(p, home) {
		t.Errorf("Path %q not under questmaster home %q", p, home)
	}
	for _, repoish := range []string{"/.wt/", "/worktree", "questmaster/internal", "/.git/"} {
		if strings.Contains(p, repoish) {
			t.Errorf("Path %q looks like it points into a repo (%q)", p, repoish)
		}
	}
}

func TestStoreLoadRejectsUnsafeID(t *testing.T) {
	s := newTestStore(t)
	if _, err := s.Load("../escape"); err == nil {
		t.Fatalf("Load accepted an unsafe id, want refusal")
	}
}

func TestQuestsDirHonorsHomeEnv(t *testing.T) {
	t.Setenv(HomeEnv, "/tmp/qm-home-test")
	if got := QuestsDir(); got != "/tmp/qm-home-test/quests" {
		t.Errorf("QuestsDir = %q, want /tmp/qm-home-test/quests", got)
	}
}
