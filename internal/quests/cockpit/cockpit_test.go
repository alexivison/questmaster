package cockpit

import (
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"

	"github.com/alexivison/questmaster/internal/quests/quest"
	"github.com/alexivison/questmaster/internal/quests/runtime"
)

// recorder captures action-hook invocations for assertions.
type recorder struct {
	opened   string
	diffed   string
	edited   string
	jumped   string
	spawned  string // title passed to SpawnFree
	authored string // quest id passed to Author
}

func testSources(rec *recorder) Sources {
	sessions := []SessionRow{
		// webapp: a master with two workers, plus a solo
		{ID: "qm-1", Title: "ENG-142", Repo: "webapp", Agent: "claude", Role: "master", State: "working", Activity: "delegating"},
		{ID: "qm-1a", Title: "impl", Repo: "webapp", Agent: "claude", Role: "worker", State: "working", Activity: "edit auth.go", Parent: "qm-1"},
		{ID: "qm-1b", Title: "rsrch", Repo: "webapp", Agent: "codex", Role: "worker", State: "done", Activity: "deps done", Parent: "qm-1"},
		{ID: "qm-2", Title: "ENG-138", Repo: "webapp", Agent: "claude", Role: "solo", State: "idle"},
		// infra: a blocked solo
		{ID: "qm-3", Title: "ENG-131", Repo: "infra", Agent: "codex", Role: "solo", State: "blocked", Activity: "stuck"},
	}
	quests := []quest.Quest{
		{ID: "ENG-142", Goal: "first quest goal", Gates: []quest.Gate{{Name: "ci", Type: quest.GateAuto, Check: "github:checks"}}, Worktree: "webapp/.wt/eng-142"},
		{ID: "ENG-138", Goal: "second quest goal", Next: []string{"do a thing"}},
	}
	records := map[string]*runtime.RuntimeRecord{
		"ENG-142": {
			QuestID:     "ENG-142",
			Status:      runtime.StatusInProgress,
			GateResults: map[string]string{"ci": "green"},
			Sessions:    []runtime.SessionRef{{ID: "qm-1", Role: "master", Agent: "claude", State: "working"}},
			PR:          &runtime.PRStatus{Number: 441, CI: "green", Review: "pending"},
		},
		"ENG-138": {QuestID: "ENG-138", Status: runtime.StatusDraft, GateResults: map[string]string{}},
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
		Jump: func(id string) tea.Cmd {
			if rec != nil {
				rec.jumped = id
			}
			return func() tea.Msg { return ActionResult{} }
		},
		SpawnFree: func(title string) tea.Cmd {
			if rec != nil {
				rec.spawned = "spawn:" + title
			}
			return func() tea.Msg { return Spawned{ID: "qm-new"} }
		},
		Author: func(id string) tea.Cmd {
			if rec != nil {
				rec.authored = id
			}
			return func() tea.Msg { return Spawned{ID: "qm-plan"} }
		},
	}
}

func sized(m Model) Model {
	nm, _ := m.update(tea.WindowSizeMsg{Width: 140, Height: 40})
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
	case "shift+tab":
		msg = tea.KeyMsg{Type: tea.KeyShiftTab}
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

func TestListPopulationAndRepoGrouping(t *testing.T) {
	m := loaded(sized(New(testSources(nil))))
	if len(m.sessions) != 5 {
		t.Errorf("sessions = %d, want 5", len(m.sessions))
	}
	if m.selectableCount() != 5 {
		t.Errorf("selectable sessions = %d, want 5", m.selectableCount())
	}
	v := view(m)
	for _, want := range []string{"webapp", "infra", "ENG-142", "ENG-138", "ENG-131", "first quest goal"} {
		if !strings.Contains(v, want) {
			t.Errorf("view missing %q\n%s", want, v)
		}
	}
	// Detail pane hidden by default (scan mode) — it should not show the
	// detail-only "steer" line or PR section yet.
	if strings.Contains(v, "steer") {
		t.Errorf("detail pane should be hidden by default\n%s", v)
	}
}

func TestWorkerNesting(t *testing.T) {
	m := loaded(sized(New(testSources(nil))))
	// items: [webapp header, qm-1, qm-1a, qm-1b, qm-2, infra header, qm-3]
	headers, sess := 0, 0
	for _, it := range m.items {
		if it.header {
			headers++
		} else {
			sess++
		}
	}
	if headers != 2 || sess != 5 {
		t.Fatalf("roster items: %d headers, %d sessions; want 2/5", headers, sess)
	}
	// The workers must render indented with the └ connector.
	v := view(m)
	if !strings.Contains(v, "└ impl") || !strings.Contains(v, "└ rsrch") {
		t.Errorf("workers should be nested under the master\n%s", v)
	}
}

func TestDetailToggle(t *testing.T) {
	m := loaded(sized(New(testSources(nil))))
	if m.detailOpen {
		t.Fatal("detail should start closed")
	}
	// focus is quests; Enter opens detail.
	m, _ = key(m, "enter")
	if !m.detailOpen || m.focus != paneDetail {
		t.Fatalf("Enter on quests should open + focus detail (open=%v focus=%v)", m.detailOpen, m.focus)
	}
	if !strings.Contains(view(m), "steer") {
		t.Errorf("open detail should show the detail body\n%s", view(m))
	}
	// Esc closes it.
	m, _ = key(m, "esc")
	if m.detailOpen {
		t.Error("Esc should close the detail pane")
	}
}

func TestFocusSkipsClosedDetail(t *testing.T) {
	m := loaded(sized(New(testSources(nil)))) // detail closed
	if m.focus != paneQuests {
		t.Fatalf("initial focus = %v", m.focus)
	}
	m, _ = key(m, "tab") // quests -> roster (detail skipped)
	if m.focus != paneRoster {
		t.Errorf("tab with detail closed should go quests->roster, got %v", m.focus)
	}
	m, _ = key(m, "tab") // roster -> quests
	if m.focus != paneQuests {
		t.Errorf("tab wrap should return to quests, got %v", m.focus)
	}
}

func TestJumpFromRoster(t *testing.T) {
	rec := &recorder{}
	m := loaded(sized(New(testSources(rec))))
	m, _ = key(m, "tab") // focus roster
	if m.focus != paneRoster {
		t.Fatalf("focus = %v, want roster", m.focus)
	}
	_, cmd := key(m, "enter") // jump to first session (qm-1)
	if cmd == nil {
		t.Fatal("enter on roster should jump")
	}
	cmd()
	if rec.jumped != "qm-1" {
		t.Errorf("jumped to %q, want qm-1", rec.jumped)
	}
}

func TestGoKeyJumps(t *testing.T) {
	rec := &recorder{}
	m := loaded(sized(New(testSources(rec))))
	m, _ = key(m, "tab")  // roster
	m, _ = key(m, "down") // select 2nd session (qm-1a)
	_, cmd := key(m, "g")
	if cmd == nil {
		t.Fatal("g should jump")
	}
	cmd()
	if rec.jumped != "qm-1a" {
		t.Errorf("g jumped to %q, want qm-1a", rec.jumped)
	}
}

func TestSpawnFreeAttaches(t *testing.T) {
	rec := &recorder{}
	m := loaded(sized(New(testSources(rec))))
	_, cmd := key(m, "n")
	if cmd == nil {
		t.Fatal("n should spawn")
	}
	msg := cmd() // SpawnFree -> Spawned{ID:"qm-new"}
	if rec.spawned != "spawn:" {
		t.Errorf("SpawnFree called with %q", rec.spawned)
	}
	// Handling Spawned should trigger a Jump to the new session.
	m, _ = m.update(msg)
	if rec.jumped != "qm-new" {
		t.Errorf("after spawn, should jump to qm-new, got %q", rec.jumped)
	}
}

func TestAuthorFlow(t *testing.T) {
	rec := &recorder{}
	m := loaded(sized(New(testSources(rec))))
	m, _ = key(m, "a")
	if !m.authoring {
		t.Fatal("a should enter authoring input mode")
	}
	// type an id
	for _, r := range "ENG-9" {
		m, _ = m.update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}})
	}
	m, cmd := key(m, "enter")
	if m.authoring {
		t.Error("enter should leave authoring mode")
	}
	if cmd == nil {
		t.Fatal("author submit should produce a command")
	}
	cmd()
	if rec.authored != "ENG-9" {
		t.Errorf("Author called with %q, want ENG-9", rec.authored)
	}
}

func TestAuthorEscCancels(t *testing.T) {
	rec := &recorder{}
	m := loaded(sized(New(testSources(rec))))
	m, _ = key(m, "a")
	m, _ = key(m, "esc")
	if m.authoring {
		t.Error("esc should cancel authoring")
	}
	if rec.authored != "" {
		t.Error("esc should not author anything")
	}
}

func TestOpenDiffEditActions(t *testing.T) {
	rec := &recorder{}
	m := loaded(sized(New(testSources(rec))))
	m, _ = key(m, "enter") // open detail (focus detail), ENG-142 selected

	_, cmd := key(m, "o")
	if cmd != nil {
		cmd()
	}
	if rec.opened != "ENG-142" {
		t.Errorf("o opened %q, want ENG-142", rec.opened)
	}
	_, cmd = key(m, "d")
	if cmd != nil {
		cmd()
	}
	if rec.diffed != "ENG-142" {
		t.Errorf("d diffed %q, want ENG-142", rec.diffed)
	}
	_, cmd = key(m, "e")
	if cmd != nil {
		cmd()
	}
	if rec.edited != "ENG-142" {
		t.Errorf("e edited %q, want ENG-142", rec.edited)
	}
}

func TestDetailShowsGatesPRWhenOpen(t *testing.T) {
	m := loaded(sized(New(testSources(nil))))
	m, _ = key(m, "enter") // open detail
	v := view(m)
	for _, want := range []string{"ci", "auto", "✓", "#441", "gates", "in_progress"} {
		if !strings.Contains(v, want) {
			t.Errorf("open detail missing %q\n%s", want, v)
		}
	}
}

func TestQuitKey(t *testing.T) {
	m := loaded(sized(New(testSources(nil))))
	nm, cmd := key(m, "q")
	if !nm.quitting || cmd == nil {
		t.Error("q should quit")
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
	m := New(testSources(nil))
	nm, _ := m.update(tea.WindowSizeMsg{Width: 10, Height: 4})
	if !strings.Contains(nm.View(), "too small") {
		t.Errorf("tiny terminal should render a too-small notice")
	}
}
