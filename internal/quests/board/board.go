// Package board is the quests app: the standalone TUI "board" launched in a
// shell pane. It groups the store's quests (on the board / drafts / turned in),
// renders each row with the terminal renderer's RenderListRow and the selected
// quest with RenderDetail in a scrollable viewport, and drives the human-only
// actions (check / edit / open / approve / done). It is modelled on
// internal/picker. wip rows are shown but excluded from the attachable set.
package board

import (
	"time"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/alexivison/questmaster/internal/quests/quest"
)

// pollInterval is the board's live-refresh cadence, matching the tracker's.
// Each tick re-reads the store and re-derives runtime in one scan pass, so
// gate verdicts, loop phase, and party activity stay current while a quest is
// being worked.
const pollInterval = 3 * time.Second

// RuntimeFunc returns the derived runtime (sessions on the quest, their live
// activity, observed gate results) for a set of quest ids in one pass.
// Injected so the board never imports the session-scan layer directly and
// stays unit-testable.
type RuntimeFunc func(questIDs []string) map[string]quest.Runtime

// store is the subset of the quest store the board needs.
type store interface {
	List() ([]quest.Quest, error)
	Load(id string) (*quest.Quest, error)
	Save(q *quest.Quest) error
	Delete(id string) error
}

// reloadMsg asks the model to re-read the store (after an external edit/open).
type reloadMsg struct{}

// tickMsg drives the periodic monitor refresh.
type tickMsg time.Time

func tickCmd() tea.Cmd {
	return tea.Tick(pollInterval, func(t time.Time) tea.Msg { return tickMsg(t) })
}

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

	// quests is the full store set; visible is the subset shown under the
	// selected tab (filtered by status, then GroupByProject order). The cursor
	// indexes visible.
	quests       []quest.Quest
	visible      []quest.Quest
	tab          statusTab
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

// statusTab is the board's selected status category. The board shows one tab
// at a time; the default on open is the middle tab, Active.
type statusTab int

const (
	tabDrafts statusTab = iota // wip
	tabActive                  // active (default)
	tabDone                    // done
)

// tabDefs is the tab bar in display order, each with its label and status.
var tabDefs = []struct {
	tab    statusTab
	label  string
	status quest.Status
}{
	{tabDrafts, "Drafts", quest.StatusWIP},
	{tabActive, "Active", quest.StatusActive},
	{tabDone, "Done", quest.StatusDone},
}

// status maps a tab to the quest status it shows.
func (t statusTab) status() quest.Status {
	switch t {
	case tabDrafts:
		return quest.StatusWIP
	case tabDone:
		return quest.StatusDone
	default: // tabActive
		return quest.StatusActive
	}
}

// next / prev cycle the tabs with wraparound (Done → Drafts, Drafts → Done).
func (t statusTab) next() statusTab {
	if t == tabDone {
		return tabDrafts
	}
	return t + 1
}

func (t statusTab) prev() statusTab {
	if t == tabDrafts {
		return tabDone
	}
	return t - 1
}

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

// NewModel builds a board model. The default tab is Active (the middle tab).
func NewModel(s store, runtimeFor RuntimeFunc, cmds Commands) Model {
	m := Model{
		store:      s,
		runtimeFor: runtimeFor,
		cmds:       cmds,
		runtime:    map[string]quest.Runtime{},
		tab:        tabActive,
	}
	m.reload()
	return m
}

// Init arms the periodic monitor refresh.
func (m Model) Init() tea.Cmd { return tickCmd() }

// reload re-reads the store, recomputes per-quest runtime (one scan pass),
// and rebuilds the visible set for the current tab. The selected tab is
// preserved, and so is the selection identity: reloads land on a timer now,
// so a row shift (a quest approved elsewhere, a new quest saved) must move
// the cursor WITH the selected quest, not leave it pointing at a different
// row. Only when the selected quest left the tab does the selection fall
// back (and detail focus/scroll reset).
func (m *Model) reload() {
	selectedID := ""
	if q, ok := m.Selected(); ok {
		selectedID = q.ID
	}

	qs, err := m.store.List()
	if err != nil {
		m.lastErr = err
		return
	}
	m.quests = qs
	m.visible = orderedVisible(qs, m.tab)

	m.runtime = make(map[string]quest.Runtime, len(qs))
	if m.runtimeFor != nil {
		ids := make([]string, len(qs))
		for i, q := range qs {
			ids[i] = q.ID
		}
		m.runtime = m.runtimeFor(ids)
	}

	if idx := questIndex(m.visible, selectedID); idx >= 0 {
		m.cursor = idx
	} else {
		m.clampCursor()
		if selectedID != "" {
			// The selected quest left this tab; its detail pane is gone too.
			m.detailScroll = 0
			m.detailCursor = 0
			m.focus = focusList
		}
	}
	// The selected quest may have fewer interactive rows after an external
	// edit; keep the detail cursor in range.
	if n := len(m.detailTargets()); m.detailCursor >= n {
		m.detailCursor = max(0, n-1)
	}
}

// questIndex locates a quest id in the visible rows, -1 when absent.
func questIndex(qs []quest.Quest, id string) int {
	if id == "" {
		return -1
	}
	for i, q := range qs {
		if q.ID == id {
			return i
		}
	}
	return -1
}

// orderedVisible is the rows shown under a tab: the full set filtered to the
// tab's status, then laid out in project-section order (the cursor indexes
// this). Within a tab all rows share one status, so GroupByProject reduces to
// project sections then id.
func orderedVisible(quests []quest.Quest, tab statusTab) []quest.Quest {
	want := tab.status()
	var filtered []quest.Quest
	for _, q := range quests {
		if q.Status == want {
			filtered = append(filtered, q)
		}
	}
	ordered := make([]quest.Quest, 0, len(filtered))
	for _, g := range quest.GroupByProject(filtered) {
		ordered = append(ordered, g.Quests...)
	}
	return ordered
}

// setTab switches the selected tab, rebuilds the visible set, and resets the
// cursor to the top.
func (m *Model) setTab(t statusTab) {
	m.tab = t
	m.visible = orderedVisible(m.quests, t)
	m.cursor = 0
	m.detailScroll = 0
	m.detailCursor = 0
}

func (m *Model) clampCursor() {
	if m.cursor < 0 {
		m.cursor = 0
	}
	if m.cursor >= len(m.visible) {
		m.cursor = max(0, len(m.visible)-1)
	}
}

// Group is one labelled section of the board: a project (the section header)
// and the quests under it, in row order.
type Group struct {
	Label  string
	Quests []quest.Quest
}

// Groups returns the current tab's project sections in display order. The
// visible set is already filtered to the tab's status; this maps the shared
// grouping onto the board's display type.
func (m Model) Groups() []Group {
	pgs := quest.GroupByProject(m.visible)
	groups := make([]Group, len(pgs))
	for i, pg := range pgs {
		groups[i] = Group{Label: pg.Project, Quests: pg.Quests}
	}
	return groups
}

// AttachableQuests is the selectable set for spawn/attach: active only. It reads
// the FULL store set, not the visible tab, so attach works no matter which tab
// is showing.
func (m Model) AttachableQuests() []quest.Quest {
	var out []quest.Quest
	for _, q := range m.quests {
		if q.Status == quest.StatusActive {
			out = append(out, q)
		}
	}
	return out
}

// Selected returns the visible quest under the cursor.
func (m Model) Selected() (quest.Quest, bool) {
	if m.cursor < 0 || m.cursor >= len(m.visible) {
		return quest.Quest{}, false
	}
	return m.visible[m.cursor], true
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
	case tickMsg:
		m.reload()
		return m, tickCmd()
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
	case "tab":
		m.setTab(m.tab.next())
	case "shift+tab":
		m.setTab(m.tab.prev())
	case "l", "right", "enter":
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
	case "x":
		m.deleteSelected()
	}
	return m, nil
}

// deleteSelected removes the cursor's quest immediately (no confirmation,
// matching `questmaster quest delete`) and reloads, which reclamps the cursor.
// A no-op on an empty board; any store error surfaces in the footer.
func (m *Model) deleteSelected() {
	q, ok := m.Selected()
	if !ok {
		return
	}
	if err := m.store.Delete(q.ID); err != nil {
		m.lastErr = err
		return
	}
	m.reload()
}

// handleDetailKey drives the detail pane's interactive rows: move between
// toggle gates / related entries, flip a toggle, and (T12) open a related url.
func (m Model) handleDetailKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "esc", "h", "left", "q":
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
	if len(m.visible) == 0 {
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
