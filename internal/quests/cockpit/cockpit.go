// Package cockpit is the Quests dashboard: the quest plan layer — a quests
// list and a toggleable detail pane (head + runtime overlay + PR/CI), polled
// live. It is deliberately quests-only; the agents/sessions experience is the
// reused questmaster tracker (`quests agents`), which is also the in-session
// sidebar. Spawning and jumping to sessions live there, so the dashboard never
// navigates away and is always there to return to.
//
// The model is pure over injected Sources, so it is fully unit-testable without
// a terminal; the binary wires real sources (and the tmux/exec side effects).
package cockpit

import (
	"time"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/alexivison/questmaster/internal/quests/quest"
	"github.com/alexivison/questmaster/internal/quests/runtime"
)

// pollInterval is the live-refresh cadence for the quests list + runtime.
const pollInterval = 2 * time.Second

type pane int

const (
	paneQuests pane = iota
	paneDetail
)

// Sources are the injected data + action hooks the dashboard runs over. Diff
// and Edit return tea.Cmds so the binary can relinquish the terminal
// (tea.ExecProcess) and return to the dashboard when the viewer/editor closes.
type Sources struct {
	Quests      func() ([]quest.Quest, error)
	Runtime     func(id string) (*runtime.RuntimeRecord, error)
	OpenBrowser func(id string) error // non-blocking (xdg-open)
	Diff        func(id string) tea.Cmd
	Edit        func(id string) tea.Cmd
}

// Model is the dashboard Bubble Tea model.
type Model struct {
	sources Sources

	width, height int
	focus         pane
	detailOpen    bool

	quests   []quest.Quest
	questSel int

	detail       *runtime.RuntimeRecord
	detailScroll int

	status   string
	err      error
	quitting bool
}

// New builds a dashboard model over the given sources.
func New(sources Sources) Model {
	return Model{sources: sources, focus: paneQuests}
}

// --- messages ---

type dataMsg struct {
	quests []quest.Quest
	err    error
}

type runtimeMsg struct {
	id  string
	rec *runtime.RuntimeRecord
	err error
}

// ActionResult is returned by external action commands (Diff/Edit) when they
// finish, to report status/errors and optionally trigger a reload. Exported so
// the binary's tea.Exec callbacks can emit it.
type ActionResult struct {
	Text   string
	Err    error
	Reload bool
}

type tickMsg time.Time

// Init loads data and starts the live-refresh tick.
func (m Model) Init() tea.Cmd {
	return tea.Batch(m.loadCmd(), tickCmd())
}

// Update implements tea.Model.
func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	nm, cmd := m.update(msg)
	return nm, cmd
}

func (m Model) update(msg tea.Msg) (Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		return m, nil

	case tickMsg:
		// Live refresh: reload quests + the selected runtime, then re-arm.
		return m, tea.Batch(m.loadCmd(), m.loadRuntimeCmd(), tickCmd())

	case dataMsg:
		m.err = msg.err
		m.quests = msg.quests
		m.clampSelection()
		return m, m.loadRuntimeCmd()

	case runtimeMsg:
		if id, ok := m.selectedQuestID(); ok && id == msg.id {
			m.detail = msg.rec
			if msg.err != nil {
				m.err = msg.err
			}
		}
		return m, nil

	case ActionResult:
		if msg.Err != nil {
			m.err = msg.Err
		} else if msg.Text != "" {
			m.status = msg.Text
			m.err = nil
		}
		if msg.Reload {
			return m, m.loadCmd()
		}
		return m, nil

	case tea.KeyMsg:
		return m.handleKey(msg)
	}
	return m, nil
}

func (m Model) handleKey(msg tea.KeyMsg) (Model, tea.Cmd) {
	switch msg.String() {
	case "q", "ctrl+c":
		m.quitting = true
		return m, tea.Quit

	case "esc":
		if m.detailOpen {
			m.detailOpen = false
			m.focus = paneQuests
		}
		return m, nil

	case "tab", "shift+tab":
		if m.detailOpen {
			if m.focus == paneQuests {
				m.focus = paneDetail
			} else {
				m.focus = paneQuests
			}
		}
		return m, nil

	case "enter", "right", "l":
		if m.focus == paneQuests {
			m.detailOpen = true
			m.focus = paneDetail
			return m, m.loadRuntimeCmd()
		}
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
			return m, m.sources.Diff(id)
		}
		return m, nil

	case "e":
		if id, ok := m.selectedQuestID(); ok && m.sources.Edit != nil {
			return m, m.sources.Edit(id)
		}
		return m, nil
	}
	return m, nil
}

func (m Model) moveSelection(delta int) (Model, tea.Cmd) {
	if m.focus == paneDetail {
		m.detailScroll = clamp(m.detailScroll+delta, 0, 1<<30)
		return m, nil
	}
	prev := m.questSel
	m.questSel = clamp(m.questSel+delta, 0, len(m.quests)-1)
	if m.questSel != prev {
		m.detailScroll = 0
		m.detail = nil
		return m, m.loadRuntimeCmd()
	}
	return m, nil
}

func (m *Model) clampSelection() {
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

func tickCmd() tea.Cmd {
	return tea.Tick(pollInterval, func(t time.Time) tea.Msg { return tickMsg(t) })
}

func (m Model) loadCmd() tea.Cmd {
	return func() tea.Msg { return m.loadData() }
}

func (m Model) loadData() dataMsg {
	var out dataMsg
	if m.sources.Quests != nil {
		q, err := m.sources.Quests()
		out.quests = q
		out.err = err
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
			return ActionResult{Err: err}
		}
		return ActionResult{Text: text}
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
