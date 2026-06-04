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

// errMsg carries an injected command's failure back to the board so it shows in
// the footer instead of failing silently.
type errMsg struct{ err error }

// ErrCmd wraps an error as the tea.Msg the board surfaces in its footer.
// Injected open/check commands return it (instead of ReloadCmd) when their
// side effect fails — e.g. `check` on an unattached quest with no worktree.
func ErrCmd(err error) tea.Msg { return errMsg{err} }

// Model is the Bubble Tea model for the quests board.
type Model struct {
	store      store
	runtimeFor RuntimeFunc
	// cmds are the side-effecting actions, injected by the launcher (which owns
	// the terminal handover and the gate runner); tests inject recorders.
	cmds Commands

	quests       []quest.Quest
	runtime      map[string]quest.Runtime
	cursor       int
	detailScroll int
	width        int
	height       int
	lastErr      error
	quit         bool

	// focus is which pane has the keyboard: the list, or the detail pane's
	// interactive rows. detailCursor indexes DetailTargets of the selected quest.
	focus        paneFocus
	detailCursor int
}

// paneFocus is which pane the keyboard drives.
type paneFocus int

const (
	focusList paneFocus = iota
	focusDetail
)

// Commands are the board's injected side effects. Any may be nil in tests that
// only exercise grouping/selection/transitions.
type Commands struct {
	// Open opens the quest's HTML in the browser; Edit edits its JSON; Check
	// runs its auto gates and writes the sidecar. Each returns a tea.Cmd that
	// should emit ReloadCmd when the board needs to refresh.
	Open  func(id string) tea.Cmd
	Edit  func(id string) tea.Cmd
	Check func(id string) tea.Cmd
	// OpenURL opens a related entry's url with the OS opener (read-only).
	OpenURL func(url string) tea.Cmd
}

// NewModel builds a board model.
func NewModel(s store, runtimeFor RuntimeFunc, cmds Commands) Model {
	m := Model{
		store:      s,
		runtimeFor: runtimeFor,
		cmds:       cmds,
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
	case errMsg:
		m.lastErr = msg.err
		return m, nil
	case tea.KeyMsg:
		return m.handleKey(msg)
	}
	return m, nil
}

func (m Model) handleKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	m.lastErr = nil
	if msg.String() == "ctrl+c" {
		m.quit = true
		return m, tea.Quit
	}
	if m.focus == focusDetail {
		return m.handleDetailKey(msg)
	}
	return m.handleListKey(msg)
}

// handleListKey drives the grouped list: navigation, status moves, open/edit,
// and entering the detail pane.
func (m Model) handleListKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "q", "esc":
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
	case "r":
		m.reload()
	case "l", "right", "tab", "enter":
		m.enterDetail()
	case "o":
		if q, ok := m.Selected(); ok && m.cmds.Open != nil {
			return m, m.cmds.Open(q.ID)
		}
	case "e":
		if q, ok := m.Selected(); ok && m.cmds.Edit != nil {
			return m, m.cmds.Edit(q.ID)
		}
	case "c":
		if q, ok := m.Selected(); ok && m.cmds.Check != nil {
			return m, m.cmds.Check(q.ID)
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

// handleDetailKey drives the detail pane's interactive rows: move between
// toggle gates / related entries, flip a toggle, and (T12) open a related url.
func (m Model) handleDetailKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "esc", "h", "left", "tab", "q":
		m.focus = focusList
	case "j", "down":
		m.moveDetailCursor(1)
	case "k", "up":
		m.moveDetailCursor(-1)
	case "ctrl+f":
		m.detailScroll++
	case "ctrl+b":
		if m.detailScroll > 0 {
			m.detailScroll--
		}
	case "r":
		m.reload()
	case " ", "x":
		m.toggleFocusedGate()
	case "o":
		if cmd := m.openFocusedRelated(); cmd != nil {
			return m, cmd
		}
	}
	return m, nil
}

// openFocusedRelated opens the focused related entry's url with the OS opener.
// Read-only — no JSON write. The OS opener routes by url scheme (https → the
// browser, slack:// → the app), so no per-type handling is needed here.
func (m Model) openFocusedRelated() tea.Cmd {
	tgt, ok := m.currentTarget()
	if !ok || tgt.Kind != quest.TargetRelated || m.cmds.OpenURL == nil {
		return nil
	}
	q, ok := m.Selected()
	if !ok || tgt.Index < 0 || tgt.Index >= len(q.Related) {
		return nil
	}
	url := q.Related[tgt.Index].URL
	if url == "" {
		return nil
	}
	return m.cmds.OpenURL(url)
}

func (m *Model) moveCursor(delta int) {
	if len(m.quests) == 0 {
		return
	}
	m.cursor += delta
	m.clampCursor()
	m.detailScroll = 0
	m.detailCursor = 0
}

// enterDetail focuses the detail pane, if the selected quest has any
// interactive rows (toggle gates or related entries).
func (m *Model) enterDetail() {
	q, ok := m.Selected()
	if !ok || len(quest.DetailTargets(&q)) == 0 {
		return
	}
	m.focus = focusDetail
	m.detailCursor = 0
}

func (m *Model) moveDetailCursor(delta int) {
	n := len(m.detailTargets())
	if n == 0 {
		return
	}
	m.detailCursor += delta
	if m.detailCursor < 0 {
		m.detailCursor = 0
	}
	if m.detailCursor >= n {
		m.detailCursor = n - 1
	}
}

// detailTargets are the interactive rows of the currently selected quest.
func (m Model) detailTargets() []quest.DetailTarget {
	q, ok := m.Selected()
	if !ok {
		return nil
	}
	return quest.DetailTargets(&q)
}

// currentTarget is the focused interactive row, if any.
func (m Model) currentTarget() (quest.DetailTarget, bool) {
	targets := m.detailTargets()
	if m.detailCursor < 0 || m.detailCursor >= len(targets) {
		return quest.DetailTarget{}, false
	}
	return targets[m.detailCursor], true
}

// detailFocus is the focus descriptor handed to the renderer.
func (m Model) detailFocus() quest.DetailFocus {
	if m.focus != focusDetail {
		return quest.DetailFocus{}
	}
	tgt, ok := m.currentTarget()
	if !ok {
		return quest.DetailFocus{}
	}
	return quest.DetailFocus{Active: true, Kind: tgt.Kind, Index: tgt.Index}
}

// toggleFocusedGate flips the focused toggle gate's checked state and persists
// it through the same validate-write-rebuild Save path the status moves use.
// Only toggle gates flip — the agent and auto gates never set this.
func (m *Model) toggleFocusedGate() {
	tgt, ok := m.currentTarget()
	if !ok || tgt.Kind != quest.TargetGate {
		return
	}
	q, ok := m.Selected()
	if !ok || tgt.Index < 0 || tgt.Index >= len(q.Gates) {
		return
	}
	if q.Gates[tgt.Index].Type != quest.GateToggle {
		return
	}
	q.Gates[tgt.Index].Checked = !q.Gates[tgt.Index].Checked
	m.persist(&q)
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
