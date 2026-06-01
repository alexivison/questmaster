package cockpit

import (
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"

	"github.com/alexivison/questmaster/internal/quests/quest"
	"github.com/alexivison/questmaster/internal/quests/runtime"
)

type recorder struct {
	opened string
	diffed string
	edited string
}

func testSources(rec *recorder) Sources {
	quests := []quest.Quest{
		{ID: "ENG-142", Goal: "first quest goal", Gates: []quest.Gate{{Name: "ci", Type: quest.GateAuto, Check: "github:checks"}, {Name: "ui", Type: quest.GateToggle}}, Worktree: "webapp/.wt/eng-142"},
		{ID: "ENG-138", Goal: "second quest goal", Next: []string{"do a thing"}},
	}
	records := map[string]*runtime.RuntimeRecord{
		"ENG-142": {
			QuestID:     "ENG-142",
			Status:      runtime.StatusInProgress,
			GateResults: map[string]string{"ci": "green"},
			PR:          &runtime.PRStatus{Number: 441, CI: "green", Review: "pending"},
		},
		"ENG-138": {QuestID: "ENG-138", Status: runtime.StatusDraft, GateResults: map[string]string{}},
	}
	return Sources{
		Quests: func() ([]quest.Quest, error) { return quests, nil },
		Runtime: func(id string) (*runtime.RuntimeRecord, error) {
			if r, ok := records[id]; ok {
				return r, nil
			}
			return &runtime.RuntimeRecord{QuestID: id, Status: runtime.StatusDraft}, nil
		},
		OpenBrowser: func(id string) error {
			if rec != nil {
				rec.opened = id
			}
			return nil
		},
		Diff: func(id string) tea.Cmd {
			if rec != nil {
				rec.diffed = id
			}
			return func() tea.Msg { return ActionResult{Text: "diff"} }
		},
		Edit: func(id string) tea.Cmd {
			if rec != nil {
				rec.edited = id
			}
			return func() tea.Msg { return ActionResult{Text: "edit", Reload: true} }
		},
	}
}

func sized(m Model) Model {
	nm, _ := m.update(tea.WindowSizeMsg{Width: 120, Height: 40})
	return nm
}

func loaded(m Model) Model {
	m, cmd := m.update(m.loadData())
	if cmd != nil {
		m, _ = m.update(cmd())
	}
	return m
}

func key(m Model, s string) (Model, tea.Cmd) {
	var msg tea.KeyMsg
	switch s {
	case "tab":
		msg = tea.KeyMsg{Type: tea.KeyTab}
	case "enter":
		msg = tea.KeyMsg{Type: tea.KeyEnter}
	case "esc":
		msg = tea.KeyMsg{Type: tea.KeyEsc}
	case "up":
		msg = tea.KeyMsg{Type: tea.KeyUp}
	case "down":
		msg = tea.KeyMsg{Type: tea.KeyDown}
	default:
		msg = tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(s)}
	}
	return m.update(msg)
}

func view(m Model) string { return ansi.Strip(m.View()) }

func TestListPopulation(t *testing.T) {
	m := loaded(sized(New(testSources(nil))))
	if len(m.quests) != 2 {
		t.Errorf("quests = %d, want 2", len(m.quests))
	}
	v := view(m)
	for _, want := range []string{"quests", "ENG-142", "ENG-138", "first quest goal", "auto", "tog"} {
		if !strings.Contains(v, want) {
			t.Errorf("view missing %q\n%s", want, v)
		}
	}
	// Detail closed by default.
	if m.detailOpen || strings.Contains(v, "from quest file") {
		t.Errorf("detail should be closed by default\n%s", v)
	}
}

func TestDetailToggle(t *testing.T) {
	m := loaded(sized(New(testSources(nil))))
	m, _ = key(m, "enter")
	if !m.detailOpen || m.focus != paneDetail {
		t.Fatalf("enter should open + focus detail (open=%v focus=%v)", m.detailOpen, m.focus)
	}
	v := view(m)
	for _, want := range []string{"ci", "auto", "✓", "#441", "in_progress", "gates"} {
		if !strings.Contains(v, want) {
			t.Errorf("open detail missing %q\n%s", want, v)
		}
	}
	m, _ = key(m, "esc")
	if m.detailOpen {
		t.Error("esc should close detail")
	}
}

func TestQuestNavigation(t *testing.T) {
	m := loaded(sized(New(testSources(nil))))
	if id, _ := m.selectedQuestID(); id != "ENG-142" {
		t.Fatalf("initial selection = %q, want ENG-142", id)
	}
	m, cmd := key(m, "down")
	if m.questSel != 1 {
		t.Fatalf("down should move to index 1")
	}
	if cmd != nil {
		m, _ = m.update(cmd()) // apply runtime load
	}
	if m.detail == nil || m.detail.QuestID != "ENG-138" {
		t.Errorf("detail should follow selection to ENG-138, got %+v", m.detail)
	}
	// Clamp at the end.
	m, _ = key(m, "down")
	if m.questSel != 1 {
		t.Errorf("selection should clamp at the last quest")
	}
}

func TestActions(t *testing.T) {
	rec := &recorder{}
	m := loaded(sized(New(testSources(rec))))

	if _, cmd := key(m, "o"); cmd != nil {
		cmd()
	}
	if rec.opened != "ENG-142" {
		t.Errorf("o opened %q, want ENG-142", rec.opened)
	}
	if _, cmd := key(m, "d"); cmd != nil {
		cmd()
	}
	if rec.diffed != "ENG-142" {
		t.Errorf("d diffed %q, want ENG-142", rec.diffed)
	}
	if _, cmd := key(m, "e"); cmd != nil {
		cmd()
	}
	if rec.edited != "ENG-142" {
		t.Errorf("e edited %q, want ENG-142", rec.edited)
	}
}

func TestLivePollRefreshes(t *testing.T) {
	// Quests source whose contents change between polls.
	calls := 0
	first := []quest.Quest{{ID: "Q1", Goal: "one"}}
	second := []quest.Quest{{ID: "Q1", Goal: "one"}, {ID: "Q2", Goal: "two"}}
	src := Sources{
		Quests: func() ([]quest.Quest, error) {
			calls++
			if calls == 1 {
				return first, nil
			}
			return second, nil
		},
		Runtime: func(id string) (*runtime.RuntimeRecord, error) {
			return &runtime.RuntimeRecord{QuestID: id, Status: runtime.StatusDraft}, nil
		},
	}
	m := sized(New(src))
	m, _ = m.update(m.loadData()) // first load: 1 quest
	if len(m.quests) != 1 {
		t.Fatalf("first load = %d quests, want 1", len(m.quests))
	}
	// Simulate a poll tick → reloads.
	m, cmd := m.update(tickMsg{})
	_ = cmd
	m, _ = m.update(m.loadData()) // second load: 2 quests
	if len(m.quests) != 2 {
		t.Errorf("after poll = %d quests, want 2 (real-time refresh)", len(m.quests))
	}
}

func TestEmptyState(t *testing.T) {
	src := Sources{
		Quests:  func() ([]quest.Quest, error) { return nil, nil },
		Runtime: func(id string) (*runtime.RuntimeRecord, error) { return &runtime.RuntimeRecord{QuestID: id}, nil },
	}
	m := loaded(sized(New(src)))
	if !strings.Contains(view(m), "no quests yet") {
		t.Errorf("empty dashboard should say 'no quests yet'\n%s", view(m))
	}
}

func TestQuitKey(t *testing.T) {
	m := loaded(sized(New(testSources(nil))))
	nm, cmd := key(m, "q")
	if !nm.quitting || cmd == nil {
		t.Error("q should quit")
	}
}

func TestTooSmall(t *testing.T) {
	m := New(testSources(nil))
	nm, _ := m.update(tea.WindowSizeMsg{Width: 10, Height: 4})
	if !strings.Contains(nm.View(), "too small") {
		t.Error("tiny terminal should render a too-small notice")
	}
}
