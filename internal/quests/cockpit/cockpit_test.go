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

func testRows() []QuestRow {
	return []QuestRow{
		{
			Quest: quest.Quest{
				ID: "ENG-142", Goal: "first quest goal",
				Gates:    []quest.Gate{{Name: "ci", Type: quest.GateAuto, Check: "github:checks"}, {Name: "ui", Type: quest.GateToggle}},
				Worktree: "webapp/.wt/eng-142",
			},
			Runtime: &runtime.RuntimeRecord{
				QuestID: "ENG-142", Status: runtime.StatusInProgress,
				GateResults: map[string]string{"ci": "green"},
				Sessions:    []runtime.SessionRef{{ID: "qm-1", Role: "master", Agent: "claude", State: "working"}},
				PR:          &runtime.PRStatus{Number: 441, CI: "green", Review: "pending"},
			},
		},
		{
			Quest:   quest.Quest{ID: "ENG-138", Goal: "second quest goal", Next: []string{"do a thing"}},
			Runtime: &runtime.RuntimeRecord{QuestID: "ENG-138", Status: runtime.StatusDraft, GateResults: map[string]string{}},
		},
	}
}

func testSources(rec *recorder) Sources {
	return Sources{
		Rows: func() ([]QuestRow, error) { return testRows(), nil },
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
	m, _ = m.update(m.loadData())
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

func TestListPopulationAndPerQuestStatus(t *testing.T) {
	m := loaded(sized(New(testSources(nil))))
	if len(m.rows) != 2 {
		t.Errorf("rows = %d, want 2", len(m.rows))
	}
	v := view(m)
	// Header + ids + goal + per-quest gate chips + PR marker visible in the list.
	for _, want := range []string{"✦ quests", "ENG-142", "ENG-138", "first quest goal", "ci", "ui", "#441"} {
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
	for _, want := range []string{"ci", "auto", "in_progress", "gates", "sessions", "claude"} {
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
	m, _ = key(m, "down")
	if id, _ := m.selectedQuestID(); id != "ENG-138" {
		t.Errorf("down should select ENG-138, got %q", id)
	}
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
	calls := 0
	src := Sources{
		Rows: func() ([]QuestRow, error) {
			calls++
			rows := []QuestRow{{Quest: quest.Quest{ID: "Q1", Goal: "one"}}}
			if calls > 1 {
				rows = append(rows, QuestRow{Quest: quest.Quest{ID: "Q2", Goal: "two"}})
			}
			return rows, nil
		},
	}
	m := sized(New(src))
	m, _ = m.update(m.loadData())
	if len(m.rows) != 1 {
		t.Fatalf("first load = %d rows, want 1", len(m.rows))
	}
	m, _ = m.update(tickMsg{}) // re-arms + reloads
	m, _ = m.update(m.loadData())
	if len(m.rows) != 2 {
		t.Errorf("after poll = %d rows, want 2 (real-time refresh)", len(m.rows))
	}
}

func TestEmptyState(t *testing.T) {
	src := Sources{Rows: func() ([]QuestRow, error) { return nil, nil }}
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
