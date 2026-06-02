package board

import (
	"path/filepath"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"

	"github.com/alexivison/questmaster/internal/quests/quest"
)

func strip(s string) string { return ansi.Strip(s) }

func newStore(t *testing.T) *quest.FileStore {
	t.Helper()
	return quest.NewStore(filepath.Join(t.TempDir(), "quests"))
}

func save(t *testing.T, s *quest.FileStore, id string, status quest.Status) {
	t.Helper()
	q := &quest.Quest{ID: id, Title: id, Summary: "goal of " + id, Status: status,
		Gates: []quest.Gate{{Name: "tests", Type: quest.GateAuto, Check: "cmd:make test"}}}
	if err := s.Save(q); err != nil {
		t.Fatalf("save %s: %v", id, err)
	}
}

func key(s string) tea.KeyMsg {
	if len(s) == 1 {
		return tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(s)}
	}
	return tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(s)}
}

func update(m Model, msg tea.Msg) (Model, tea.Cmd) {
	next, cmd := m.Update(msg)
	return next.(Model), cmd
}

func TestGroupsFromStore(t *testing.T) {
	s := newStore(t)
	save(t, s, "ACT-1", quest.StatusActive)
	save(t, s, "ACT-2", quest.StatusActive)
	save(t, s, "WIP-1", quest.StatusWIP)
	save(t, s, "DONE-1", quest.StatusDone)

	m := NewModel(s, nil, nil, nil)
	groups := m.Groups()
	if len(groups) != 3 {
		t.Fatalf("got %d groups, want 3", len(groups))
	}
	if groups[0].Label != "On the board" || len(groups[0].Quests) != 2 {
		t.Errorf("group 0 = %q (%d), want On the board (2)", groups[0].Label, len(groups[0].Quests))
	}
	if groups[1].Label != "Drafts" || groups[1].Status != quest.StatusWIP {
		t.Errorf("group 1 = %q", groups[1].Label)
	}
	if groups[2].Label != "Turned in" || groups[2].Status != quest.StatusDone {
		t.Errorf("group 2 = %q", groups[2].Label)
	}
}

func TestWIPExcludedFromAttachableSet(t *testing.T) {
	s := newStore(t)
	save(t, s, "ACT-1", quest.StatusActive)
	save(t, s, "WIP-1", quest.StatusWIP)
	save(t, s, "DONE-1", quest.StatusDone)

	m := NewModel(s, nil, nil, nil)
	att := m.AttachableQuests()
	if len(att) != 1 || att[0].ID != "ACT-1" {
		t.Fatalf("AttachableQuests = %v, want [ACT-1] (wip and done excluded)", ids(att))
	}
}

func TestDetailPaneComesFromTerminalRenderer(t *testing.T) {
	s := newStore(t)
	save(t, s, "ACT-1", quest.StatusActive)
	m := NewModel(s, nil, nil, nil)
	m.width, m.height = 120, 60

	sel, ok := m.Selected()
	if !ok {
		t.Fatal("no selection")
	}
	detailW := m.width - (m.width*34/100) - 1
	want := quest.RenderDetail(&sel, quest.Runtime{}, detailW)
	got := strip(m.renderDetail(detailW, 60))
	if !strings.Contains(got, strip(want)) {
		t.Errorf("board detail is not the T2 render.\n got:\n%s\n want (prefix):\n%s", got, strip(want))
	}
}

func TestAttachedIndicatorFromRuntimeScan(t *testing.T) {
	s := newStore(t)
	save(t, s, "ACT-1", quest.StatusActive) // on it
	save(t, s, "ACT-2", quest.StatusActive) // waiting

	runtimeFor := func(id string) quest.Runtime {
		if id == "ACT-1" {
			return quest.Runtime{Sessions: []string{"qm-1"}}
		}
		return quest.Runtime{}
	}
	m := NewModel(s, runtimeFor, nil, nil)
	list := strip(m.renderList(40, 20))

	// ACT-1 is attached (⚔), ACT-2 is waiting.
	if !strings.Contains(list, "⚔") {
		t.Errorf("attached quest missing the on-it indicator:\n%s", list)
	}
	if !strings.Contains(list, "wait") {
		t.Errorf("unattached active quest missing the wait tag:\n%s", list)
	}
}

func TestApproveAndDoneInvokeTransitions(t *testing.T) {
	s := newStore(t)
	save(t, s, "WIP-1", quest.StatusWIP)
	m := NewModel(s, nil, nil, nil)

	// 'a' approves the wip quest → active (persisted).
	m, _ = update(m, key("a"))
	if q, _ := s.Load("WIP-1"); q.Status != quest.StatusActive {
		t.Fatalf("after approve, stored status = %q, want active", q.Status)
	}

	// Cursor still on it (now active); 'd' marks it done.
	m, _ = update(m, key("d"))
	if q, _ := s.Load("WIP-1"); q.Status != quest.StatusDone {
		t.Fatalf("after done, stored status = %q, want done", q.Status)
	}
}

func TestDoneRefusedOnWIP(t *testing.T) {
	s := newStore(t)
	save(t, s, "WIP-1", quest.StatusWIP)
	m := NewModel(s, nil, nil, nil)

	m, _ = update(m, key("d")) // wip cannot skip to done
	if q, _ := s.Load("WIP-1"); q.Status != quest.StatusWIP {
		t.Errorf("done on a wip quest changed status to %q", q.Status)
	}
	if m.lastErr == nil {
		t.Errorf("expected an error surfaced for done-on-wip")
	}
}

func TestOpenAndEditDispatch(t *testing.T) {
	s := newStore(t)
	save(t, s, "ACT-1", quest.StatusActive)

	var opened, edited string
	openCmd := func(id string) tea.Cmd { return func() tea.Msg { opened = id; return nil } }
	editCmd := func(id string) tea.Cmd { return func() tea.Msg { edited = id; return nil } }
	m := NewModel(s, nil, openCmd, editCmd)

	_, cmd := update(m, key("o"))
	if cmd == nil {
		t.Fatal("open produced no command")
	}
	cmd()
	if opened != "ACT-1" {
		t.Errorf("open dispatched for %q, want ACT-1", opened)
	}

	_, cmd = update(m, key("e"))
	if cmd == nil {
		t.Fatal("edit produced no command")
	}
	cmd()
	if edited != "ACT-1" {
		t.Errorf("edit dispatched for %q, want ACT-1", edited)
	}
}

func ids(qs []quest.Quest) []string {
	out := make([]string, len(qs))
	for i, q := range qs {
		out[i] = q.ID
	}
	return out
}
