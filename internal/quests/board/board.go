// Package board is the quests app: the standalone TUI "board" launched in a
// shell pane. It groups the store's quests (on the board / drafts / turned in),
// renders each row with the terminal renderer's RenderListRow and the selected
// quest with RenderDetail in a scrollable viewport, and drives the human-only
// actions (check / edit / open / approve / done). It is modelled on
// internal/picker. wip rows are shown but excluded from the attachable set.
package board

import (
	"sort"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/alexivison/questmaster/internal/quests/quest"
)

// RuntimeFunc returns the derived runtime (sessions on the quest) for a quest
// id. Injected so the board never imports the session-scan layer directly and
// stays unit-testable.
type RuntimeFunc func(questID string) quest.Runtime

// store is the subset of the quest store the board needs.
type store interface {
	List() ([]quest.Quest, error)
	Load(id string) (*quest.Quest, error)
	Save(q *quest.Quest) error
}

// reloadMsg asks the model to re-read the store (after an external edit/open).
type reloadMsg struct{}

// ReloadCmd is the tea.Msg that asks the board to re-read the store. Injected
// open/edit commands return it after their side effect so the board refreshes.
func ReloadCmd() tea.Msg { return reloadMsg{} }

// Model is the Bubble Tea model for the quests board.
type Model struct {
	store      store
	runtimeFor RuntimeFunc
	// openCmd / editCmd produce the tea.Cmds that open the quest in the browser
	// and edit its JSON. Injected by the launcher (which owns the terminal
	// handover); tests inject recorders.
	openCmd func(id string) tea.Cmd
	editCmd func(id string) tea.Cmd

	quests       []quest.Quest
	runtime      map[string]quest.Runtime
	cursor       int
	detailScroll int
	width        int
	height       int
	lastErr      error
	quit         bool
}

// NewModel builds a board model. runtimeFor, openCmd and editCmd may be nil in
// tests that only exercise grouping/selection/transitions.
func NewModel(s store, runtimeFor RuntimeFunc, openCmd, editCmd func(id string) tea.Cmd) Model {
	m := Model{
		store:      s,
		runtimeFor: runtimeFor,
		openCmd:    openCmd,
		editCmd:    editCmd,
		runtime:    map[string]quest.Runtime{},
	}
	m.reload()
	return m
}

// Init satisfies tea.Model.
func (m Model) Init() tea.Cmd { return nil }

// reload re-reads the store and recomputes per-quest runtime. Quests are sorted
// into board order (active, then wip, then done) and by id within a group.
func (m *Model) reload() {
	qs, err := m.store.List()
	if err != nil {
		m.lastErr = err
		return
	}
	sort.SliceStable(qs, func(i, j int) bool {
		ri, rj := groupRank(qs[i].Status), groupRank(qs[j].Status)
		if ri != rj {
			return ri < rj
		}
		return qs[i].ID < qs[j].ID
	})
	m.quests = qs

	m.runtime = make(map[string]quest.Runtime, len(qs))
	if m.runtimeFor != nil {
		for _, q := range qs {
			m.runtime[q.ID] = m.runtimeFor(q.ID)
		}
	}
	m.clampCursor()
}

func (m *Model) clampCursor() {
	if m.cursor < 0 {
		m.cursor = 0
	}
	if m.cursor >= len(m.quests) {
		m.cursor = max(0, len(m.quests)-1)
	}
}

// Group is one labelled section of the board.
type Group struct {
	Label  string
	Status quest.Status
	Quests []quest.Quest
}

// Groups returns the board's three sections in display order, omitting empties.
func (m Model) Groups() []Group {
	defs := []struct {
		label  string
		status quest.Status
	}{
		{"On the board", quest.StatusActive},
		{"Drafts", quest.StatusWIP},
		{"Turned in", quest.StatusDone},
	}
	var groups []Group
	for _, d := range defs {
		var qs []quest.Quest
		for _, q := range m.quests {
			if q.Status == d.status {
				qs = append(qs, q)
			}
		}
		if len(qs) > 0 {
			groups = append(groups, Group{Label: d.label, Status: d.status, Quests: qs})
		}
	}
	return groups
}

// AttachableQuests is the selectable set for spawn/attach: active only. wip and
// done are excluded even though they show on the board.
func (m Model) AttachableQuests() []quest.Quest {
	var out []quest.Quest
	for _, q := range m.quests {
		if q.Status == quest.StatusActive {
			out = append(out, q)
		}
	}
	return out
}

// Selected returns the quest under the cursor.
func (m Model) Selected() (quest.Quest, bool) {
	if m.cursor < 0 || m.cursor >= len(m.quests) {
		return quest.Quest{}, false
	}
	return m.quests[m.cursor], true
}

func (m Model) runtimeOf(id string) quest.Runtime { return m.runtime[id] }

// Update handles input and reload messages.
func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		return m, nil
	case reloadMsg:
		m.reload()
		return m, nil
	case tea.KeyMsg:
		return m.handleKey(msg)
	}
	return m, nil
}

func (m Model) handleKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	m.lastErr = nil
	switch msg.String() {
	case "q", "esc", "ctrl+c":
		m.quit = true
		return m, tea.Quit
	case "j", "down":
		m.moveCursor(1)
	case "k", "up":
		m.moveCursor(-1)
	case "ctrl+f":
		m.detailScroll++
	case "ctrl+b":
		if m.detailScroll > 0 {
			m.detailScroll--
		}
	case "enter", "o":
		if q, ok := m.Selected(); ok && m.openCmd != nil {
			return m, m.openCmd(q.ID)
		}
	case "e":
		if q, ok := m.Selected(); ok && m.editCmd != nil {
			return m, m.editCmd(q.ID)
		}
	case "a":
		m.setSelectedStatus(quest.StatusActive)
	case "d":
		m.setSelectedStatus(quest.StatusDone)
	case "w":
		m.setSelectedStatus(quest.StatusWIP)
	}
	return m, nil
}

func (m *Model) moveCursor(delta int) {
	if len(m.quests) == 0 {
		return
	}
	m.cursor += delta
	m.clampCursor()
	m.detailScroll = 0
}

// setSelectedStatus moves the cursor's quest to a human-owned state and
// persists it. Movement is unrestricted — a → board (active), d → turned in
// (done), w → draft (wip) — so quests can flow between states in any direction.
func (m *Model) setSelectedStatus(to quest.Status) {
	q, ok := m.Selected()
	if !ok {
		return
	}
	if q.Status == to {
		return // already there
	}
	if err := quest.SetStatus(&q, to); err != nil {
		m.lastErr = err
		return
	}
	m.persist(&q)
}

func (m *Model) persist(q *quest.Quest) {
	if err := m.store.Save(q); err != nil {
		m.lastErr = err
		return
	}
	m.reload()
}

func groupRank(s quest.Status) int {
	switch s {
	case quest.StatusActive:
		return 0
	case quest.StatusWIP:
		return 1
	default: // done
		return 2
	}
}
