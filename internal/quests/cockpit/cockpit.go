// Package cockpit is the Stage-1 three-pane TUI: an agents roster (every
// session across all repos, grouped by repo with the master→worker tree and
// the questmaster tracker's glyph vocabulary), a quests list, and a toggleable
// detail pane (selected quest's head + runtime overlay + PR/CI). It is the
// cockpit index that replaces the manual HTML-plan + index habit.
//
// The model is pure over injected Sources, so it is fully unit-testable without
// a terminal; the binary wires real sources (and the tmux/exec side effects)
// and runs it under Bubble Tea.
package cockpit

import (
	"strings"

	"github.com/charmbracelet/bubbles/textinput"
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
)

// SessionRow is a roster entry: one session, projected from the state spine.
// Parent links a worker to its master; Depth>0 renders it indented.
type SessionRow struct {
	ID       string
	Title    string
	Repo     string // working dir basename — the "across repos" grouping
	Agent    string
	Role     string // master | solo | worker
	State    string // working | done | blocked | idle | ...
	Activity string // short live activity text
	Parent   string // master's session id, "" if top-level
	Depth    int    // 0 top-level, 1 worker child
}

// Sources are the injected data + action hooks the cockpit runs over. The
// action hooks return tea.Cmds so the binary can relinquish the terminal
// (tea.Exec) for attach/diff/edit; tests inject recording stubs.
type Sources struct {
	Sessions    func() ([]SessionRow, error)
	Quests      func() ([]quest.Quest, error)
	Runtime     func(id string) (*runtime.RuntimeRecord, error)
	OpenBrowser func(id string) error          // non-blocking (xdg-open)
	Diff        func(id string) tea.Cmd        // launches the diff viewer
	Edit        func(id string) tea.Cmd        // $EDITOR on the quest file
	Jump        func(sessionID string) tea.Cmd // tmux switch-client / attach
	SpawnFree   func(title string) tea.Cmd     // spawn a free session -> spawnedMsg
	Author      func(questID string) tea.Cmd   // new quest + planning master -> spawnedMsg
}

// Model is the cockpit Bubble Tea model.
type Model struct {
	sources Sources

	width, height int
	focus         pane
	detailOpen    bool

	sessions  []SessionRow
	items     []rosterItem // computed display order (repo headers + sessions)
	rosterSel int          // index into the selectable (non-header) items
	quests    []quest.Quest
	questSel  int

	detail       *runtime.RuntimeRecord
	detailScroll int

	authoring bool
	input     textinput.Model

	status   string
	err      error
	quitting bool
}

// rosterItem is one rendered roster line: a repo header or a session.
type rosterItem struct {
	header bool
	repo   string
	sess   SessionRow
}

// New builds a cockpit model over the given sources.
func New(sources Sources) Model {
	ti := textinput.New()
	ti.Prompt = "new quest id › "
	ti.CharLimit = 64
	return Model{sources: sources, focus: paneQuests, input: ti}
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

// Spawned is returned by SpawnFree/Author once a session id exists; the cockpit
// reloads its lists and attaches to the session via Jump. It is exported so the
// binary's spawn commands can emit it.
type Spawned struct {
	ID  string
	Err error
}

// ActionResult is returned by external action commands (Diff/Edit/Jump) when
// they finish, to report status/errors back into the cockpit and optionally
// trigger a reload. Exported for the binary's tea.Exec callbacks.
type ActionResult struct {
	Text   string
	Err    error
	Reload bool
}

// Init loads the initial data.
func (m Model) Init() tea.Cmd { return m.loadCmd() }

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
		m.items = buildRoster(msg.sessions)
		m.quests = msg.quests
		m.clampSelections()
		return m, m.loadRuntimeCmd()

	case runtimeMsg:
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
			m.err = nil
		}
		return m, nil

	case Spawned:
		if msg.Err != nil {
			m.err = msg.Err
			return m, nil
		}
		// Reload lists (a new quest/session may exist) and jump into the
		// freshly-spawned session.
		cmds := []tea.Cmd{m.loadCmd()}
		if m.sources.Jump != nil && msg.ID != "" {
			cmds = append(cmds, m.sources.Jump(msg.ID))
		}
		return m, tea.Batch(cmds...)

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
		if m.authoring {
			return m.updateAuthoring(msg)
		}
		return m.handleKey(msg)
	}
	return m, nil
}

func (m Model) updateAuthoring(msg tea.KeyMsg) (Model, tea.Cmd) {
	switch msg.String() {
	case "esc":
		m.authoring = false
		m.input.Blur()
		return m, nil
	case "enter":
		id := strings.TrimSpace(m.input.Value())
		m.authoring = false
		m.input.Blur()
		if id == "" || m.sources.Author == nil {
			return m, nil
		}
		m.status = "authoring " + id + "…"
		return m, m.sources.Author(id)
	}
	var cmd tea.Cmd
	m.input, cmd = m.input.Update(msg)
	return m, cmd
}

func (m Model) handleKey(msg tea.KeyMsg) (Model, tea.Cmd) {
	switch msg.String() {
	case "q", "ctrl+c":
		m.quitting = true
		return m, tea.Quit

	case "esc":
		if m.detailOpen {
			m.detailOpen = false
			if m.focus == paneDetail {
				m.focus = paneQuests
			}
		}
		return m, nil

	case "tab", "right", "l":
		m.focus = m.nextFocus(1)
		return m, nil
	case "shift+tab", "left", "h":
		m.focus = m.nextFocus(-1)
		return m, nil

	case "up", "k":
		return m.moveSelection(-1)
	case "down", "j":
		return m.moveSelection(1)

	case "enter":
		switch m.focus {
		case paneRoster:
			return m.jumpSelected()
		case paneQuests:
			m.detailOpen = true
			m.focus = paneDetail
			return m, m.loadRuntimeCmd()
		}
		return m, nil

	case "r":
		m.status = ""
		return m, m.loadCmd()

	case "a": // author a new quest interactively
		m.authoring = true
		m.input.SetValue("")
		m.input.Focus()
		return m, textinput.Blink

	case "n": // spawn a free session
		if m.sources.SpawnFree != nil {
			m.status = "spawning session…"
			return m, m.sources.SpawnFree("")
		}
		return m, nil

	case "g": // go to / jump to the selected roster session
		return m.jumpSelected()

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

// nextFocus advances focus, skipping the detail pane when it's closed.
func (m Model) nextFocus(delta int) pane {
	order := []pane{paneRoster, paneQuests}
	if m.detailOpen {
		order = append(order, paneDetail)
	}
	cur := 0
	for i, p := range order {
		if p == m.focus {
			cur = i
		}
	}
	n := (cur + delta + len(order)) % len(order)
	return order[n]
}

func (m Model) jumpSelected() (Model, tea.Cmd) {
	s, ok := m.selectedSession()
	if !ok || m.sources.Jump == nil {
		return m, nil
	}
	m.status = "→ " + s.ID
	return m, m.sources.Jump(s.ID)
}

func (m Model) moveSelection(delta int) (Model, tea.Cmd) {
	switch m.focus {
	case paneRoster:
		m.rosterSel = clamp(m.rosterSel+delta, 0, m.selectableCount()-1)
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
	m.rosterSel = clamp(m.rosterSel, 0, m.selectableCount()-1)
	m.questSel = clamp(m.questSel, 0, len(m.quests)-1)
}

func (m Model) selectableCount() int {
	n := 0
	for _, it := range m.items {
		if !it.header {
			n++
		}
	}
	return n
}

func (m Model) selectedSession() (SessionRow, bool) {
	n := 0
	for _, it := range m.items {
		if it.header {
			continue
		}
		if n == m.rosterSel {
			return it.sess, true
		}
		n++
	}
	return SessionRow{}, false
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

// buildRoster groups sessions by repo and nests workers under their master.
func buildRoster(sessions []SessionRow) []rosterItem {
	workersByParent := map[string][]SessionRow{}
	var tops []SessionRow
	for _, s := range sessions {
		if s.Parent != "" {
			workersByParent[s.Parent] = append(workersByParent[s.Parent], s)
		} else {
			tops = append(tops, s)
		}
	}
	// Repo order follows first appearance in the (mtime-sorted) input, so the
	// repo with the most-recent activity leads — matching the cockpit mock,
	// not an alphabetical sort.
	byRepo := map[string][]SessionRow{}
	var repos []string
	for _, s := range tops {
		key := s.Repo
		if _, ok := byRepo[key]; !ok {
			repos = append(repos, key)
		}
		byRepo[key] = append(byRepo[key], s)
	}

	var items []rosterItem
	for _, repo := range repos {
		items = append(items, rosterItem{header: true, repo: repoLabel(repo)})
		for _, s := range byRepo[repo] {
			items = append(items, rosterItem{sess: s})
			for _, w := range workersByParent[s.ID] {
				w.Depth = 1
				items = append(items, rosterItem{sess: w})
			}
		}
	}
	return items
}

func repoLabel(repo string) string {
	if repo == "" {
		return "(no repo)"
	}
	return repo
}

// --- commands ---

func (m Model) loadCmd() tea.Cmd {
	return func() tea.Msg { return m.loadData() }
}

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
