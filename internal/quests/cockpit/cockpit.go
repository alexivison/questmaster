// Package cockpit is the Stage-1 three-pane TUI: an agents roster (every
// session across all repos), a quests list, and a detail pane (selected quest's
// head + runtime overlay + PR/CI, with open-in-browser and launch-diff keys).
// It is the cockpit index that replaces the manual HTML-plan + index habit.
//
// The model is pure over injected Sources, so it is fully unit-testable without
// a terminal; the binary wires real sources and runs it under Bubble Tea.
package cockpit

import (
	tea "github.com/charmbracelet/bubbletea"

	"github.com/alexivison/questmaster/internal/quests/quest"
	"github.com/alexivison/questmaster/internal/quests/runtime"
)

// pane identifies a focusable pane.
type pane int

const (
	paneRoster pane = iota
	paneQuests
	paneDetail
	paneCount
)

// SessionRow is a roster entry: one session, projected from the state spine.
type SessionRow struct {
	ID    string
	Title string
	Repo  string // working dir basename — the "across repos" column
	Agent string
	Role  string
	State string
}

// Sources are the injected data + action hooks the cockpit runs over.
type Sources struct {
	Sessions    func() ([]SessionRow, error)
	Quests      func() ([]quest.Quest, error)
	Runtime     func(id string) (*runtime.RuntimeRecord, error)
	OpenBrowser func(id string) error // open the quest HTML in the browser
	Diff        func(id string) error // launch the diff viewer for the quest
}

// Model is the cockpit Bubble Tea model.
type Model struct {
	sources Sources

	width, height int
	focus         pane

	sessions  []SessionRow
	quests    []quest.Quest
	rosterSel int
	questSel  int

	detail       *runtime.RuntimeRecord
	detailScroll int

	status   string
	err      error
	quitting bool
}

// New builds a cockpit model over the given sources.
func New(sources Sources) Model {
	return Model{sources: sources, focus: paneQuests}
}

// --- messages ---

type dataMsg struct {
	sessions []SessionRow
	quests   []quest.Quest
	err      error
}

type runtimeMsg struct {
	id  string
	rec *runtime.RuntimeRecord
	err error
}

type actionMsg struct {
	text string
	err  error
}

// Init loads the initial data.
func (m Model) Init() tea.Cmd {
	return m.loadCmd()
}

// Update implements tea.Model.
func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	nm, cmd := m.update(msg)
	return nm, cmd
}

// update is the concrete-typed reducer (used directly by tests).
func (m Model) update(msg tea.Msg) (Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		return m, nil

	case dataMsg:
		m.err = msg.err
		m.sessions = msg.sessions
		m.quests = msg.quests
		m.clampSelections()
		return m, m.loadRuntimeCmd()

	case runtimeMsg:
		// Only apply if it still matches the selection.
		if id, ok := m.selectedQuestID(); ok && id == msg.id {
			m.detail = msg.rec
			if msg.err != nil {
				m.err = msg.err
			}
		}
		return m, nil

	case actionMsg:
		if msg.err != nil {
			m.err = msg.err
		} else if msg.text != "" {
			m.status = msg.text
		}
		return m, nil

	case tea.KeyMsg:
		return m.handleKey(msg)
	}
	return m, nil
}

func (m Model) handleKey(msg tea.KeyMsg) (Model, tea.Cmd) {
	switch msg.String() {
	case "q", "ctrl+c", "esc":
		m.quitting = true
		return m, tea.Quit

	case "tab", "right", "l":
		m.focus = (m.focus + 1) % paneCount
		return m, nil
	case "shift+tab", "left", "h":
		m.focus = (m.focus + paneCount - 1) % paneCount
		return m, nil

	case "up", "k":
		return m.moveSelection(-1)
	case "down", "j":
		return m.moveSelection(1)

	case "r":
		m.status = ""
		return m, m.loadCmd()

	case "o":
		if id, ok := m.selectedQuestID(); ok && m.sources.OpenBrowser != nil {
			return m, runAction("opened "+id, func() error { return m.sources.OpenBrowser(id) })
		}
		return m, nil

	case "d":
		if id, ok := m.selectedQuestID(); ok && m.sources.Diff != nil {
			return m, runAction("diff "+id, func() error { return m.sources.Diff(id) })
		}
		return m, nil
	}
	return m, nil
}

// moveSelection moves the selection (or detail scroll) in the focused pane.
func (m Model) moveSelection(delta int) (Model, tea.Cmd) {
	switch m.focus {
	case paneRoster:
		m.rosterSel = clamp(m.rosterSel+delta, 0, len(m.sessions)-1)
		return m, nil
	case paneQuests:
		prev := m.questSel
		m.questSel = clamp(m.questSel+delta, 0, len(m.quests)-1)
		if m.questSel != prev {
			m.detailScroll = 0
			m.detail = nil
			return m, m.loadRuntimeCmd()
		}
		return m, nil
	case paneDetail:
		m.detailScroll = clamp(m.detailScroll+delta, 0, 1<<30)
		return m, nil
	}
	return m, nil
}

func (m *Model) clampSelections() {
	m.rosterSel = clamp(m.rosterSel, 0, len(m.sessions)-1)
	m.questSel = clamp(m.questSel, 0, len(m.quests)-1)
}

func (m Model) selectedQuestID() (string, bool) {
	if m.questSel >= 0 && m.questSel < len(m.quests) {
		return m.quests[m.questSel].ID, true
	}
	return "", false
}

func (m Model) selectedQuest() (quest.Quest, bool) {
	if m.questSel >= 0 && m.questSel < len(m.quests) {
		return m.quests[m.questSel], true
	}
	return quest.Quest{}, false
}

// --- commands ---

func (m Model) loadCmd() tea.Cmd {
	return func() tea.Msg { return m.loadData() }
}

// loadData fetches sessions + quests (synchronous; wrapped in a Cmd / called by
// tests directly).
func (m Model) loadData() dataMsg {
	var out dataMsg
	if m.sources.Sessions != nil {
		s, err := m.sources.Sessions()
		out.sessions = s
		if err != nil {
			out.err = err
		}
	}
	if m.sources.Quests != nil {
		q, err := m.sources.Quests()
		out.quests = q
		if err != nil && out.err == nil {
			out.err = err
		}
	}
	return out
}

func (m Model) loadRuntimeCmd() tea.Cmd {
	id, ok := m.selectedQuestID()
	if !ok || m.sources.Runtime == nil {
		return nil
	}
	return func() tea.Msg {
		rec, err := m.sources.Runtime(id)
		return runtimeMsg{id: id, rec: rec, err: err}
	}
}

func runAction(text string, fn func() error) tea.Cmd {
	return func() tea.Msg {
		if err := fn(); err != nil {
			return actionMsg{err: err}
		}
		return actionMsg{text: text}
	}
}

func clamp(v, lo, hi int) int {
	if hi < lo {
		return lo
	}
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}
