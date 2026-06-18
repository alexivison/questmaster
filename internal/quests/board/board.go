// Package board is the quests app: the standalone TUI "board" launched in a
// shell pane. It groups the store's quests (on the board / drafts / turned in),
// renders each row with the terminal renderer's RenderListRow and the selected
// quest with RenderDetail in a scrollable viewport, and drives the human-only
// actions (check / edit / open / approve / done). It is modelled on
// internal/picker. wip rows are shown but excluded from the attachable set.
package board

import (
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/textarea"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/alexivison/questmaster/internal/quests/quest"
)

// pollInterval is the board's live-refresh cadence, matching the tracker's.
// Each tick re-reads the store and re-derives runtime in one scan pass, so
// gate verdicts, loop phase, and adventurer activity stay current while a quest is
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
	// detailManualScroll is set by explicit detail viewport scrolling. When it
	// is false, the detail pane auto-follows the focused toggle/link row.
	detailManualScroll bool
	width              int
	height             int
	lastErr            error
	quit               bool

	// focus is which pane has the keyboard: the list, or the detail pane's
	// interactive rows. detailCursor indexes DetailTargets of the selected quest.
	focus        paneFocus
	detailCursor int

	composer *commentComposer

	// contentVersion bumps whenever a reload changes what the panes render:
	// the quest set, the structural runtime (sessions/agents/gates/loop), or
	// any live activity (durations/verdict ages advance with the poll clock).
	// It is the cache-busting half of the frame key — view-state changes
	// (cursor, tab, focus, scroll) are captured by the key directly.
	contentVersion int
	// lastFP / lastRuntimeSig are the previous poll's store fingerprint and
	// structural runtime signature, used to detect "nothing changed" ticks so a
	// reload can skip the parse and leave contentVersion (and the frame cache)
	// untouched. loaded guards the first reload, which always reads.
	lastFP         string
	lastRuntimeSig string
	loaded         bool

	// frame caches the last rendered View output, keyed on contentVersion plus
	// view-state. View has a value receiver, so the cache lives behind a pointer
	// shared across model copies; Bubble Tea drives Update/View on one goroutine,
	// so the single-entry box is only ever touched sequentially. Mirrors the
	// tracker's normalFrameCache. Bypassed while the comment composer is open
	// (its textarea changes per keystroke without a reload).
	frame *frameCacheBox
	// detail memoizes the detail-pane render within one frame: scroll math
	// (currentDetailStart, detailLineCount) and View's renderDetail otherwise
	// re-render the whole detail body 2-3x per keystroke with identical inputs.
	detail *detailMemoBox
}

// frameCacheKey identifies a fully-rendered board frame. All fields are
// comparable so the whole key compares in one ==, with no allocation.
type frameCacheKey struct {
	version            int
	tab                statusTab
	cursor             int
	detailCursor       int
	detailScroll       int
	detailManualScroll bool
	focus              paneFocus
	width              int
	height             int
	lastErr            string
}

type frameCacheBox struct {
	key   frameCacheKey
	frame string
	valid bool
}

// detailMemoKey identifies a detail-pane render. CommentAnchor carries an
// *int, so the focus is flattened into comparable fields rather than embedded.
type detailMemoKey struct {
	questID     string
	version     int
	width       int
	focusActive bool
	focusKind   quest.DetailTargetKind
	focusIndex  int
	focusItem   int
	anchorKind  quest.CommentAnchorKind
	anchorID    string
	anchorItem  int
	commentID   string
}

type detailMemoBox struct {
	key       detailMemoKey
	lines     []string
	selection quest.DetailLineSelection
	valid     bool
}

type commentComposer struct {
	QuestID             string
	CommentID           string
	Anchor              quest.CommentAnchor
	PendingRelatedIndex int
	PendingBodyIndex    int
	PendingItemIndex    int
	Editor              textarea.Model
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
	Open           func(id string) tea.Cmd
	Edit           func(id string) tea.Cmd
	Check          func(id string) tea.Cmd
	ResolveComment func(id, commentID string) tea.Cmd
	DeleteComment  func(id, commentID string) tea.Cmd
	Now            func() time.Time
	Author         func() string
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
		frame:      &frameCacheBox{},
		detail:     &detailMemoBox{},
	}
	if m.cmds.Now == nil {
		m.cmds.Now = time.Now
	}
	if m.cmds.Author == nil {
		m.cmds.Author = func() string { return "" }
	}
	m.reload()
	return m
}

// Init arms the periodic monitor refresh.
func (m Model) Init() tea.Cmd { return tickCmd() }

// reload re-reads the store unconditionally and rebuilds the visible set. It is
// the explicit-refresh path (the `r` key, a post-edit reloadMsg, and the
// board's own writes), so it must always re-read — a fingerprint can collide
// (same size + mtime) and `r` has to stay a reliable "force re-read".
func (m *Model) reload() { m.refresh(true) }

// pollReload is the timer path: it skips the parse-heavy store read when the
// on-disk fingerprint is unchanged since the last poll (B2), so an idle board
// does not re-read and re-group every quest file every 3s.
func (m *Model) pollReload() { m.refresh(false) }

// refresh re-reads the store (always when force, else fingerprint-gated),
// recomputes per-quest runtime (one scan pass), and rebuilds the visible set
// for the current tab. The selected tab is preserved, and so is the selection
// identity: reloads land on a timer now, so a row shift (a quest approved
// elsewhere, a new quest saved) must move the cursor WITH the selected quest,
// not leave it pointing at a different row. Only when the selected quest left
// the tab does the selection fall back (and detail focus/scroll reset).
func (m *Model) refresh(force bool) {
	selectedID := ""
	if q, ok := m.Selected(); ok {
		selectedID = q.ID
	}

	// Runtime is always refreshed below — it is live and not reflected in the
	// file fingerprint.
	questsChanged := true
	fp, fpOK := m.storeFingerprint()
	if !force && fpOK && m.loaded && fp == m.lastFP {
		questsChanged = false
	} else {
		qs, err := m.store.List()
		if err != nil {
			m.lastErr = err
			return
		}
		m.quests = qs
		m.visible = orderedVisible(qs, m.tab)
		m.lastFP = fp
	}
	m.loaded = true

	m.runtime = make(map[string]quest.Runtime, len(m.quests))
	if m.runtimeFor != nil {
		ids := make([]string, len(m.quests))
		for i, q := range m.quests {
			ids[i] = q.ID
		}
		m.runtime = m.runtimeFor(ids)
	}

	// Bump the frame-cache version only when the rendered content actually
	// changed: the quest set, the structural runtime, or any live activity
	// (durations/verdict ages advance with each poll). Idle boards (no attached
	// sessions, no observed gates, no loop) keep a stable version across ticks,
	// so View serves the cached frame and allocates nothing.
	sig := runtimeSignature(m.runtime, m.quests)
	if questsChanged || sig != m.lastRuntimeSig || hasLiveRuntime(m.runtime) {
		m.contentVersion++
	}
	m.lastRuntimeSig = sig

	if idx := questIndex(m.visible, selectedID); idx >= 0 {
		m.cursor = idx
	} else {
		m.clampCursor()
		if selectedID != "" {
			// The selected quest left this tab; its detail pane is gone too.
			m.detailScroll = 0
			m.detailManualScroll = false
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

// fingerprinter is the optional fast-path a store can offer: a cheap signature
// of its contents that changes iff a quest file changed. *quest.FileStore
// implements it; stores that do not simply read on every reload (the prior
// behaviour), so the gate is purely an optimisation.
type fingerprinter interface {
	Fingerprint() (string, error)
}

// storeFingerprint returns the store's content fingerprint and whether the
// store supports the fast-path at all.
func (m *Model) storeFingerprint() (string, bool) {
	fp, ok := m.store.(fingerprinter)
	if !ok {
		return "", false
	}
	sig, err := fp.Fingerprint()
	if err != nil {
		return "", false
	}
	return sig, true
}

// runtimeSignature is a compact, time-free signature of the structural runtime
// state the panes render: attached sessions, agent, observed gate verdicts,
// adventurer activity, and the loop label. Clock-driven fields (ObservedAt,
// adventurer Since, GatesAt) are deliberately excluded — those advance every
// poll and are handled by hasLiveRuntime, not by treating every tick as a
// structural change.
func runtimeSignature(rt map[string]quest.Runtime, quests []quest.Quest) string {
	if len(rt) == 0 {
		return ""
	}
	var b strings.Builder
	for _, q := range quests { // quests are id-sorted, so the order is stable
		r, ok := rt[q.ID]
		if !ok {
			continue
		}
		b.WriteString(q.ID)
		b.WriteByte('|')
		b.WriteString(strings.Join(r.Sessions, ","))
		b.WriteByte('|')
		b.WriteString(r.Agent)
		b.WriteByte('|')
		if len(r.Gates) > 0 {
			names := make([]string, 0, len(r.Gates))
			for name := range r.Gates {
				names = append(names, name)
			}
			sort.Strings(names)
			for _, name := range names {
				b.WriteString(name)
				b.WriteByte('=')
				b.WriteString(r.Gates[name])
				b.WriteByte(';')
			}
		}
		b.WriteByte('|')
		for _, a := range r.Adventurers {
			b.WriteString(a.ID)
			b.WriteByte(':')
			b.WriteString(a.Agent)
			b.WriteByte(':')
			b.WriteString(a.State)
			b.WriteByte(';')
		}
		b.WriteByte('|')
		if r.Loop != nil {
			b.WriteString(r.Loop.Label())
		}
		b.WriteByte('\n')
	}
	return b.String()
}

// hasLiveRuntime reports whether any runtime entry has clock-driven content —
// attached sessions/adventurers (state durations), observed gate verdicts
// (verdict ages), or an armed loop. When true, the rendered output drifts with
// the poll clock even if nothing structural changed, so the frame must be
// re-rendered each poll; when false the board is idle and the cache holds.
func hasLiveRuntime(rt map[string]quest.Runtime) bool {
	for _, r := range rt {
		if len(r.Sessions) > 0 || len(r.Adventurers) > 0 || len(r.Gates) > 0 || r.Loop != nil {
			return true
		}
	}
	return false
}

// setTab switches the selected tab, rebuilds the visible set, and resets the
// cursor to the top.
func (m *Model) setTab(t statusTab) {
	m.tab = t
	m.visible = orderedVisible(m.quests, t)
	m.cursor = 0
	m.detailScroll = 0
	m.detailManualScroll = false
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
		m.pollReload()
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
	if m.composer != nil {
		return m.handleComposerKey(msg)
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
	case "pgdown", "ctrl+f":
		m.scrollDetail(m.detailPageStep())
	case "pgup", "ctrl+b":
		m.scrollDetail(-m.detailPageStep())
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

// handleDetailKey drives the detail pane's interactive rows and viewport:
// move between gates / related entries, flip toggle gates, scroll, and open a
// related url.
func (m Model) handleDetailKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "q":
		m.quit = true
		return m, tea.Quit
	case "esc", "h", "left":
		m.focus = focusList
	case "j", "down":
		if len(m.detailTargets()) <= 1 {
			m.scrollDetail(1)
		} else if !m.moveDetailCursor(1) {
			m.scrollDetail(1)
		}
	case "k", "up":
		if len(m.detailTargets()) <= 1 {
			m.scrollDetail(-1)
		} else if !m.moveDetailCursor(-1) {
			m.scrollDetail(-1)
		}
	case "pgdown", "ctrl+f":
		m.scrollDetail(m.detailPageStep())
	case "pgup", "ctrl+b":
		m.scrollDetail(-m.detailPageStep())
	case "r":
		m.reload()
	case " ", "x":
		m.toggleFocusedGate()
	case "m":
		m.startCommentComposer()
	case "e":
		m.startCommentEditComposer()
	case "D":
		if cmd := m.deleteFocusedComment(); cmd != nil {
			return m, cmd
		}
	case "R":
		if cmd := m.resolveFocusedComment(); cmd != nil {
			return m, cmd
		}
	case "o":
		if cmd := m.openFocusedRelated(); cmd != nil {
			return m, cmd
		}
	}
	return m, nil
}

func (m Model) handleComposerKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "esc":
		m.composer = nil
		return m, nil
	case "enter", "ctrl+s":
		m.postComposerComment()
		return m, nil
	case "alt+enter", "ctrl+j":
		return m.updateComposerEditor(tea.KeyMsg{Type: tea.KeyEnter})
	}
	return m.updateComposerEditor(msg)
}

func (m Model) updateComposerEditor(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	m.configureCommentTextarea(&m.composer.Editor)
	editor, cmd := m.composer.Editor.Update(msg)
	editor = syncCommentTextareaViewport(editor)
	m.composer.Editor = editor
	return m, cmd
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

func (m *Model) startCommentComposer() {
	q, ok := m.Selected()
	if !ok {
		return
	}
	tgt, ok := m.currentTarget()
	if !ok || tgt.Kind == quest.TargetComment {
		return
	}
	anchor := tgt.Anchor
	pendingRelatedIndex := -1
	pendingBodyIndex := -1
	pendingItemIndex := -1
	if anchor.Kind == "" {
		switch tgt.Kind {
		case quest.TargetRelated:
			var err error
			var pending bool
			anchor, pending, err = previewRelatedAnchor(&q, tgt.Index)
			if err != nil {
				m.lastErr = err
				return
			}
			if pending {
				pendingRelatedIndex = tgt.Index
			}
		case quest.TargetBody, quest.TargetListItem:
			var err error
			var pending bool
			anchor, pending, err = previewBodyBlockAnchor(&q, tgt.Index)
			if err != nil {
				m.lastErr = err
				return
			}
			if pending {
				pendingBodyIndex = tgt.Index
			}
		default:
			return
		}
	}
	if tgt.Kind == quest.TargetListItem && anchor.Kind != "" && anchor.Item == nil {
		anchor = anchor.WithItem(tgt.ItemIndex)
		if pendingBodyIndex >= 0 {
			pendingItemIndex = tgt.ItemIndex
		}
	}
	ed := m.newCommentTextarea("")
	m.composer = &commentComposer{
		QuestID:             q.ID,
		Anchor:              anchor,
		PendingRelatedIndex: pendingRelatedIndex,
		PendingBodyIndex:    pendingBodyIndex,
		PendingItemIndex:    pendingItemIndex,
		Editor:              ed,
	}
}

func (m *Model) startCommentEditComposer() {
	q, ok := m.Selected()
	if !ok {
		return
	}
	tgt, ok := m.currentTarget()
	if !ok || tgt.Kind != quest.TargetComment || tgt.CommentID == "" {
		return
	}
	c, ok := quest.CommentByID(&q, tgt.CommentID)
	if !ok {
		m.lastErr = fmt.Errorf("comment %q not found", tgt.CommentID)
		return
	}
	m.composer = &commentComposer{
		QuestID:             q.ID,
		CommentID:           c.ID,
		Anchor:              c.Anchor,
		PendingRelatedIndex: -1,
		PendingBodyIndex:    -1,
		PendingItemIndex:    -1,
		Editor:              m.newCommentTextarea(c.Body),
	}
}

func (m Model) newCommentTextarea(value string) textarea.Model {
	ed := textarea.New()
	ed.Prompt = ""
	ed.Placeholder = ""
	ed.ShowLineNumbers = false
	m.configureCommentTextarea(&ed)
	plain := lipgloss.NewStyle()
	ed.FocusedStyle.CursorLine = plain
	ed.FocusedStyle.CursorLineNumber = plain
	ed.FocusedStyle.EndOfBuffer = plain
	ed.FocusedStyle.LineNumber = plain
	ed.FocusedStyle.Placeholder = plain
	ed.FocusedStyle.Prompt = plain
	ed.FocusedStyle.Text = plain
	if value != "" {
		ed.SetValue(value)
	}
	ed.Focus()
	return syncCommentTextareaViewport(ed)
}

func (m Model) configureCommentTextarea(ed *textarea.Model) {
	if ed == nil {
		return
	}
	layout := composerPanelLayoutFor(m.detailPaneWidth())
	ed.SetWidth(layout.textareaWidth)
	ed.SetHeight(composerTextareaHeight)
}

func syncCommentTextareaViewport(ed textarea.Model) textarea.Model {
	// Bubbles scrolls against the viewport content from the previous View.
	// Refresh it before a no-op update so soft-wrapped cursor tails stay visible.
	_ = ed.View()
	ed, _ = ed.Update(nil)
	return ed
}

func (m *Model) postComposerComment() {
	if m.composer == nil {
		return
	}
	body := strings.TrimSpace(m.composer.Editor.Value())
	if body == "" {
		m.lastErr = fmt.Errorf("comment body is empty")
		return
	}
	q, err := m.store.Load(m.composer.QuestID)
	if err != nil {
		m.lastErr = err
		return
	}
	if m.composer.CommentID != "" {
		if err := quest.UpdateCommentBody(q, m.composer.CommentID, body); err != nil {
			m.lastErr = err
			return
		}
		if err := m.store.Save(q); err != nil {
			m.lastErr = err
			return
		}
		m.composer = nil
		m.reload()
		return
	}

	anchor := m.composer.Anchor
	if m.composer.PendingRelatedIndex >= 0 {
		anchor, err = ensureComposerRelatedAnchor(q, m.composer)
		if err != nil {
			m.lastErr = err
			return
		}
	}
	if m.composer.PendingBodyIndex >= 0 {
		anchor, err = ensureComposerBodyAnchor(q, m.composer)
		if err != nil {
			m.lastErr = err
			return
		}
	}
	if err := quest.ValidateCommentAnchor(q, anchor); err != nil {
		m.lastErr = err
		return
	}
	now := m.cmds.Now().UTC()
	q.Comments = append(q.Comments, quest.QuestComment{
		ID:        quest.NextCommentID(q, now.Unix()),
		Anchor:    anchor,
		Status:    quest.CommentOpen,
		Author:    m.cmds.Author(),
		Body:      body,
		CreatedAt: now.Format(time.RFC3339),
	})
	if err := m.store.Save(q); err != nil {
		m.lastErr = err
		return
	}
	m.composer = nil
	m.reload()
}

func previewBodyBlockAnchor(q *quest.Quest, index int) (quest.CommentAnchor, bool, error) {
	if q == nil {
		return quest.CommentAnchor{}, false, fmt.Errorf("quest is missing")
	}
	if index < 0 || index >= len(q.Body) {
		return quest.CommentAnchor{}, false, fmt.Errorf("body block %d is out of range", index)
	}
	if q.Body[index].ID != "" {
		return quest.CommentAnchor{Kind: quest.CommentAnchorBody, ID: q.Body[index].ID}, false, nil
	}
	return quest.CommentAnchor{Kind: quest.CommentAnchorBody, ID: nextBodyBlockID(q, index)}, true, nil
}

func ensureComposerBodyAnchor(q *quest.Quest, c *commentComposer) (quest.CommentAnchor, error) {
	if q == nil {
		return quest.CommentAnchor{}, fmt.Errorf("quest is missing")
	}
	if c == nil {
		return quest.CommentAnchor{}, fmt.Errorf("comment composer is missing")
	}
	if c.PendingBodyIndex < 0 || c.PendingBodyIndex >= len(q.Body) {
		return quest.CommentAnchor{}, fmt.Errorf("body block %d is out of range", c.PendingBodyIndex)
	}
	if q.Body[c.PendingBodyIndex].ID == "" {
		id := c.Anchor.ID
		if id == "" || bodyBlockIDExistsExcept(q, id, c.PendingBodyIndex) {
			id = nextBodyBlockID(q, c.PendingBodyIndex)
		}
		q.Body[c.PendingBodyIndex].ID = id
	}
	anchor := quest.CommentAnchor{Kind: quest.CommentAnchorBody, ID: q.Body[c.PendingBodyIndex].ID}
	if c.PendingItemIndex >= 0 {
		anchor = anchor.WithItem(c.PendingItemIndex)
	}
	return anchor, nil
}

func previewRelatedAnchor(q *quest.Quest, index int) (quest.CommentAnchor, bool, error) {
	if q == nil {
		return quest.CommentAnchor{}, false, fmt.Errorf("quest is missing")
	}
	if index < 0 || index >= len(q.Related) {
		return quest.CommentAnchor{}, false, fmt.Errorf("related entry %d is out of range", index)
	}
	if q.Related[index].ID != "" {
		return quest.CommentAnchor{Kind: quest.CommentAnchorRelated, ID: q.Related[index].ID}, false, nil
	}
	return quest.CommentAnchor{Kind: quest.CommentAnchorRelated, ID: nextRelatedID(q, index)}, true, nil
}

func ensureComposerRelatedAnchor(q *quest.Quest, c *commentComposer) (quest.CommentAnchor, error) {
	if q == nil {
		return quest.CommentAnchor{}, fmt.Errorf("quest is missing")
	}
	if c == nil {
		return quest.CommentAnchor{}, fmt.Errorf("comment composer is missing")
	}
	if c.PendingRelatedIndex < 0 || c.PendingRelatedIndex >= len(q.Related) {
		return quest.CommentAnchor{}, fmt.Errorf("related entry %d is out of range", c.PendingRelatedIndex)
	}
	if q.Related[c.PendingRelatedIndex].ID == "" {
		id := c.Anchor.ID
		if id == "" || relatedIDExistsExcept(q, id, c.PendingRelatedIndex) {
			id = nextRelatedID(q, c.PendingRelatedIndex)
		}
		q.Related[c.PendingRelatedIndex].ID = id
	}
	return quest.CommentAnchor{Kind: quest.CommentAnchorRelated, ID: q.Related[c.PendingRelatedIndex].ID}, nil
}

func nextRelatedID(q *quest.Quest, index int) string {
	base := fmt.Sprintf("rel-%d", index+1)
	if !relatedIDExists(q, base) {
		return base
	}
	for suffix := 1; ; suffix++ {
		id := fmt.Sprintf("%s-%d", base, suffix)
		if !relatedIDExists(q, id) {
			return id
		}
	}
}

func relatedIDExistsExcept(q *quest.Quest, id string, except int) bool {
	for i, r := range q.Related {
		if i != except && r.ID == id {
			return true
		}
	}
	return false
}

func relatedIDExists(q *quest.Quest, id string) bool {
	for _, r := range q.Related {
		if r.ID == id {
			return true
		}
	}
	return false
}

func nextBodyBlockID(q *quest.Quest, index int) string {
	base := fmt.Sprintf("block-%d", index+1)
	if !bodyBlockIDExists(q, base) {
		return base
	}
	for suffix := 1; ; suffix++ {
		id := fmt.Sprintf("%s-%d", base, suffix)
		if !bodyBlockIDExists(q, id) {
			return id
		}
	}
}

func bodyBlockIDExistsExcept(q *quest.Quest, id string, except int) bool {
	for i, b := range q.Body {
		if i != except && b.ID == id {
			return true
		}
	}
	return false
}

func bodyBlockIDExists(q *quest.Quest, id string) bool {
	for _, b := range q.Body {
		if b.ID == id {
			return true
		}
	}
	return false
}

func (m Model) resolveFocusedComment() tea.Cmd {
	qid, commentID, ok := m.focusedComment()
	if !ok || m.cmds.ResolveComment == nil {
		return nil
	}
	return m.cmds.ResolveComment(qid, commentID)
}

func (m Model) deleteFocusedComment() tea.Cmd {
	qid, commentID, ok := m.focusedComment()
	if !ok || m.cmds.DeleteComment == nil {
		return nil
	}
	return m.cmds.DeleteComment(qid, commentID)
}

func (m Model) focusedComment() (string, string, bool) {
	q, ok := m.Selected()
	if !ok {
		return "", "", false
	}
	tgt, ok := m.currentTarget()
	if !ok || tgt.Kind != quest.TargetComment || tgt.CommentID == "" {
		return "", "", false
	}
	return q.ID, tgt.CommentID, true
}

func (m *Model) moveCursor(delta int) {
	if len(m.visible) == 0 {
		return
	}
	m.cursor += delta
	m.clampCursor()
	m.detailScroll = 0
	m.detailManualScroll = false
	m.detailCursor = 0
}

// enterDetail focuses the detail pane. Quests with no interactive rows still
// accept focus so the usual arrows/page keys can scroll long details.
func (m *Model) enterDetail() {
	q, ok := m.Selected()
	if !ok {
		return
	}
	m.focus = focusDetail
	m.detailCursor = 0
	if len(quest.DetailTargets(&q)) > 0 {
		m.detailManualScroll = false
	}
}

func (m *Model) moveDetailCursor(delta int) bool {
	n := len(m.detailTargets())
	if n == 0 {
		return false
	}
	before := m.detailCursor
	m.detailCursor += delta
	if m.detailCursor < 0 {
		m.detailCursor = 0
	}
	if m.detailCursor >= n {
		m.detailCursor = n - 1
	}
	m.detailManualScroll = false
	return m.detailCursor != before
}

func (m *Model) scrollDetail(delta int) {
	start := m.currentDetailStart() + delta
	m.detailScroll = clampDetailStart(start, m.detailLineCount(), m.detailViewportHeight())
	m.detailManualScroll = true
}

func (m Model) currentDetailStart() int {
	_, focusedLine, lineCount, height := m.detailMetrics()
	start := m.detailScroll
	if focusedLine >= 0 && !m.detailManualScroll {
		if focusedLine < start {
			start = focusedLine
		} else if focusedLine >= start+height {
			start = focusedLine - height + 1
		}
	}
	return clampDetailStart(start, lineCount, height)
}

func (m Model) detailLineCount() int {
	_, _, lineCount, _ := m.detailMetrics()
	return lineCount
}

func (m Model) detailMetrics() ([]string, int, int, int) {
	if _, ok := m.Selected(); !ok {
		return nil, -1, 0, m.detailViewportHeight()
	}
	inner := m.detailInnerWidth()
	lines, selection := m.detailSelection(inner)
	return lines, selection.Primary, len(lines), m.detailViewportHeight()
}

func (m Model) detailInnerWidth() int {
	inner := m.detailPaneWidth() - detailPadLeft - detailPadRight
	if inner < 1 {
		inner = 1
	}
	return inner
}

// detailSelection renders the selected quest's detail lines + selection set,
// memoized on (quest, contentVersion, width, focus). Within a single keystroke
// the scroll math and View's renderDetail call this 2-3x with identical inputs;
// without the memo each call re-runs the whole detail render (B4). The memo box
// is shared behind a pointer like the frame cache, and touched only on the
// single Update/View goroutine.
func (m Model) detailSelection(inner int) ([]string, quest.DetailLineSelection) {
	q, ok := m.Selected()
	if !ok {
		return nil, quest.DetailLineSelection{Primary: -1}
	}
	focus := m.detailFocus()
	key := detailMemoKey{
		questID:     q.ID,
		version:     m.contentVersion,
		width:       inner,
		focusActive: focus.Active,
		focusKind:   focus.Kind,
		focusIndex:  focus.Index,
		focusItem:   focus.ItemIndex,
		anchorKind:  focus.Anchor.Kind,
		anchorID:    focus.Anchor.ID,
		anchorItem:  -1,
		commentID:   focus.CommentID,
	}
	if focus.Anchor.Item != nil {
		key.anchorItem = *focus.Anchor.Item
	}
	if m.detail != nil && m.detail.valid && m.detail.key == key {
		return m.detail.lines, m.detail.selection
	}
	lines, selection := quest.RenderDetailLineSelection(&q, m.runtimeOf(q.ID), inner, focus)
	if m.detail != nil {
		*m.detail = detailMemoBox{key: key, lines: lines, selection: selection, valid: true}
	}
	return lines, selection
}

func (m Model) detailPaneWidth() int {
	if m.width < 1 {
		return 1
	}
	_, detailW := paneWidths(m.width)
	return detailW
}

func (m Model) detailViewportHeight() int {
	h := m.height - boardHeaderHeight - boardFooterHeight
	if h < 1 {
		return 1
	}
	return h
}

func (m Model) detailPageStep() int {
	step := m.detailViewportHeight() - 1
	if step < 1 {
		return 1
	}
	return step
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
	return quest.DetailFocus{Active: true, Kind: tgt.Kind, Index: tgt.Index, ItemIndex: tgt.ItemIndex, Anchor: tgt.Anchor, CommentID: tgt.CommentID}
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
