package cockpit

import (
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"

	"github.com/alexivison/questmaster/internal/quests/quest"
	"github.com/alexivison/questmaster/internal/quests/runtime"
)

func testSources(opened, diffed *string) Sources {
	sessions := []SessionRow{
		{ID: "qm-1", Repo: "webapp", Agent: "claude", Role: "master", State: "working"},
		{ID: "qm-2", Repo: "infra", Agent: "codex", Role: "solo", State: "idle"},
	}
	quests := []quest.Quest{
		{ID: "ENG-1", Goal: "first quest goal", Gates: []quest.Gate{{Name: "ci", Type: quest.GateAuto, Check: "github:checks"}}, Worktree: "webapp/.wt/eng-1"},
		{ID: "ENG-2", Goal: "second quest goal", Next: []string{"do a thing"}},
	}
	records := map[string]*runtime.RuntimeRecord{
		"ENG-1": {
			QuestID:     "ENG-1",
			Status:      runtime.StatusInProgress,
			GateResults: map[string]string{"ci": "green"},
			Sessions:    []runtime.SessionRef{{ID: "qm-1", Role: "master", Agent: "claude", State: "working"}},
			PR:          &runtime.PRStatus{Number: 441, CI: "green", Review: "pending"},
		},
		"ENG-2": {QuestID: "ENG-2", Status: runtime.StatusDraft, GateResults: map[string]string{}},
	}
	return Sources{
		Sessions: func() ([]SessionRow, error) { return sessions, nil },
		Quests:   func() ([]quest.Quest, error) { return quests, nil },
		Runtime: func(id string) (*runtime.RuntimeRecord, error) {
			if r, ok := records[id]; ok {
				return r, nil
			}
			return &runtime.RuntimeRecord{QuestID: id, Status: runtime.StatusDraft}, nil
		},
		OpenBrowser: func(id string) error {
			if opened != nil {
				*opened = id
			}
			return nil
		},
		Diff: func(id string) error {
			if diffed != nil {
				*diffed = id
			}
			return nil
		},
	}
}

func sized(m Model) Model {
	nm, _ := m.update(tea.WindowSizeMsg{Width: 130, Height: 40})
	return nm
}

// loaded loads sessions+quests and the runtime for the initial selection.
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
	case "shift+tab":
		msg = tea.KeyMsg{Type: tea.KeyShiftTab}
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
	m := loaded(sized(New(testSources(nil, nil))))
	if len(m.sessions) != 2 {
		t.Errorf("sessions = %d, want 2", len(m.sessions))
	}
	if len(m.quests) != 2 {
		t.Errorf("quests = %d, want 2", len(m.quests))
	}
	v := view(m)
	for _, want := range []string{"qm-1", "qm-2", "ENG-1", "ENG-2", "first quest goal"} {
		if !strings.Contains(v, want) {
			t.Errorf("rendered view missing %q\n%s", want, v)
		}
	}
}

func TestPaneFocusCycles(t *testing.T) {
	m := loaded(sized(New(testSources(nil, nil))))
	if m.focus != paneQuests {
		t.Fatalf("initial focus = %v, want paneQuests", m.focus)
	}
	m, _ = key(m, "tab")
	if m.focus != paneDetail {
		t.Errorf("after tab focus = %v, want paneDetail", m.focus)
	}
	m, _ = key(m, "tab")
	if m.focus != paneRoster {
		t.Errorf("after 2x tab focus = %v, want paneRoster", m.focus)
	}
	m, _ = key(m, "tab")
	if m.focus != paneQuests {
		t.Errorf("after 3x tab focus = %v, want wrap to paneQuests", m.focus)
	}
	// Now at paneQuests; shift+tab steps backward to paneRoster.
	m, _ = key(m, "shift+tab")
	if m.focus != paneRoster {
		t.Errorf("after shift+tab focus = %v, want paneRoster", m.focus)
	}
}

func TestQuestNavigationUpdatesDetail(t *testing.T) {
	m := loaded(sized(New(testSources(nil, nil))))
	// focus is quests; first quest selected, detail = ENG-1 (in_progress).
	if m.detail == nil || m.detail.QuestID != "ENG-1" {
		t.Fatalf("initial detail = %+v, want ENG-1", m.detail)
	}
	if !strings.Contains(view(m), "in_progress") {
		t.Errorf("detail should show ENG-1 status in_progress\n%s", view(m))
	}

	// Move down to ENG-2 and apply the runtime load it triggers.
	m, cmd := key(m, "down")
	if m.questSel != 1 {
		t.Fatalf("questSel = %d, want 1", m.questSel)
	}
	if cmd != nil {
		m, _ = m.update(cmd())
	}
	if m.detail == nil || m.detail.QuestID != "ENG-2" {
		t.Fatalf("detail after move = %+v, want ENG-2", m.detail)
	}
	if !strings.Contains(view(m), "second quest goal") {
		t.Errorf("detail should show ENG-2 goal\n%s", view(m))
	}
}

func TestRosterNavigation(t *testing.T) {
	m := loaded(sized(New(testSources(nil, nil))))
	m, _ = key(m, "tab") // -> detail
	m, _ = key(m, "tab") // -> roster
	if m.focus != paneRoster {
		t.Fatalf("focus = %v, want roster", m.focus)
	}
	m, _ = key(m, "down")
	if m.rosterSel != 1 {
		t.Errorf("rosterSel = %d, want 1", m.rosterSel)
	}
	// Clamp at the end.
	m, _ = key(m, "down")
	if m.rosterSel != 1 {
		t.Errorf("rosterSel after clamp = %d, want 1", m.rosterSel)
	}
}

func TestOpenAndDiffActions(t *testing.T) {
	var opened, diffed string
	m := loaded(sized(New(testSources(&opened, &diffed))))

	_, cmd := key(m, "o")
	if cmd == nil {
		t.Fatal("o should produce an open command")
	}
	cmd() // executes OpenBrowser
	if opened != "ENG-1" {
		t.Errorf("OpenBrowser called with %q, want ENG-1", opened)
	}

	_, cmd = key(m, "d")
	if cmd == nil {
		t.Fatal("d should produce a diff command")
	}
	cmd() // executes Diff
	if diffed != "ENG-1" {
		t.Errorf("Diff called with %q, want ENG-1", diffed)
	}
}

func TestActionStatusMessage(t *testing.T) {
	m := loaded(sized(New(testSources(nil, nil))))
	_, cmd := key(m, "o")
	msg := cmd()
	m, _ = m.update(msg)
	if !strings.Contains(view(m), "opened ENG-1") {
		t.Errorf("footer should show the open status\n%s", view(m))
	}
}

func TestRenderShowsGatesAndPRAndHints(t *testing.T) {
	m := loaded(sized(New(testSources(nil, nil))))
	v := view(m)
	for _, want := range []string{"ci", "green", "#441", "PR", "open", "diff", "quit", "gates"} {
		if !strings.Contains(v, want) {
			t.Errorf("view missing %q\n%s", want, v)
		}
	}
}

func TestQuitKey(t *testing.T) {
	m := loaded(sized(New(testSources(nil, nil))))
	nm, cmd := key(m, "q")
	if !nm.quitting {
		t.Error("q should set quitting")
	}
	if cmd == nil {
		t.Error("q should return a quit command")
	}
}

func TestEmptyStates(t *testing.T) {
	src := Sources{
		Sessions: func() ([]SessionRow, error) { return nil, nil },
		Quests:   func() ([]quest.Quest, error) { return nil, nil },
		Runtime:  func(id string) (*runtime.RuntimeRecord, error) { return &runtime.RuntimeRecord{QuestID: id}, nil },
	}
	m := loaded(sized(New(src)))
	v := view(m)
	if !strings.Contains(v, "no sessions") {
		t.Errorf("empty roster should say 'no sessions'\n%s", v)
	}
	if !strings.Contains(v, "no quests yet") {
		t.Errorf("empty quests should say 'no quests yet'\n%s", v)
	}
}

func TestTooSmall(t *testing.T) {
	m := New(testSources(nil, nil))
	nm, _ := m.update(tea.WindowSizeMsg{Width: 10, Height: 4})
	if !strings.Contains(nm.View(), "too small") {
		t.Errorf("tiny terminal should render a too-small notice")
	}
}
