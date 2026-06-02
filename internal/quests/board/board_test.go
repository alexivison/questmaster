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
	detailW := m.width - (m.width * 34 / 100) - 1
	// The board renders RenderDetail at the inner width (minus the outer gutter)
	// and left-pads each line; every non-blank T2 line must still appear.
	inner := detailW - detailPadLeft - detailPadRight
	want := strip(quest.RenderDetail(&sel, quest.Runtime{}, inner))
	got := strip(m.renderDetail(detailW, 60))
	for _, line := range strings.Split(want, "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		if !strings.Contains(got, line) {
			t.Errorf("board detail is not the T2 render — missing line %q\n got:\n%s", line, got)
		}
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

func TestStatusKeysMoveFreely(t *testing.T) {
	s := newStore(t)
	save(t, s, "Q-1", quest.StatusWIP)
	m := NewModel(s, nil, nil, nil)

	// a → board (active), d → done, w → back to draft (wip): any direction.
	steps := []struct {
		key  string
		want quest.Status
	}{
		{"a", quest.StatusActive},
		{"d", quest.StatusDone},
		{"a", quest.StatusActive}, // done → back to the board
		{"w", quest.StatusWIP},    // active → back to draft
		{"d", quest.StatusDone},   // wip → straight to done
	}
	for _, st := range steps {
		m, _ = update(m, key(st.key))
		if q, _ := s.Load("Q-1"); q.Status != st.want {
			t.Fatalf("after %q, stored status = %q, want %q", st.key, q.Status, st.want)
		}
	}
}

func TestDetailToggleFlipPersistsAndRebuilds(t *testing.T) {
	s := newStore(t)
	q := &quest.Quest{ID: "Q-1", Title: "Q-1", Summary: "s", Status: quest.StatusActive,
		Gates: []quest.Gate{
			{Name: "tests", Type: quest.GateAuto, Check: "cmd:make test"},
			{Name: "ui-ok", Type: quest.GateToggle},
		}}
	if err := s.Save(q); err != nil {
		t.Fatalf("save: %v", err)
	}
	m := NewModel(s, nil, nil, nil)

	// Enter the detail pane; the only interactive target is the toggle gate
	// (the auto gate is skipped).
	m, _ = update(m, key("l"))
	tgt, ok := m.currentTarget()
	if !ok || tgt.Kind != quest.TargetGate {
		t.Fatalf("expected a focused gate target, got %+v ok=%v", tgt, ok)
	}

	// Flip it.
	m, _ = update(m, key(" "))

	got, _ := s.Load("Q-1")
	checked := false
	for _, g := range got.Gates {
		if g.Name == "ui-ok" {
			checked = g.Checked
		}
		if g.Type == quest.GateAuto && g.Checked {
			t.Errorf("auto gate %q must never be checked", g.Name)
		}
	}
	if !checked {
		t.Fatalf("toggle gate not checked after flip: %+v", got.Gates)
	}
	// The rebuilt HTML reflects the flip.
	raw, _ := quest.Build(got)
	if !strings.Contains(string(raw), "[x]") {
		t.Errorf("rebuilt HTML missing the checked box")
	}
}

func TestDetailFocusNavigationAndExit(t *testing.T) {
	s := newStore(t)
	q := &quest.Quest{ID: "Q-1", Title: "Q-1", Summary: "s", Status: quest.StatusActive,
		Gates:   []quest.Gate{{Name: "a", Type: quest.GateToggle}, {Name: "b", Type: quest.GateToggle}},
		Related: []quest.RelatedLink{{Title: "NEXT-1"}}}
	if err := s.Save(q); err != nil {
		t.Fatalf("save: %v", err)
	}
	m := NewModel(s, nil, nil, nil)
	if m.focus != focusList {
		t.Fatalf("board should start in list focus")
	}
	m, _ = update(m, key("l")) // enter detail
	if m.focus != focusDetail {
		t.Fatalf("'l' did not enter detail focus")
	}
	m, _ = update(m, key("j")) // move down two targets
	m, _ = update(m, key("j"))
	if tgt, _ := m.currentTarget(); tgt.Kind != quest.TargetRelated {
		t.Errorf("after two downs, focus should be on the related entry, got %+v", tgt)
	}
	m, _ = update(m, key("esc")) // leave
	if m.focus != focusList {
		t.Errorf("esc did not return to list focus")
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
