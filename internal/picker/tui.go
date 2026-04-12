package picker

import (
	"context"
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"

	"github.com/anthropics/ai-party/tools/party-cli/internal/state"
	"github.com/anthropics/ai-party/tools/party-cli/internal/tmux"
)

// DeleteFunc deletes a session by ID (typically session.Service.Delete).
type DeleteFunc func(ctx context.Context, sessionID string) error

// mode controls whether the picker shows the session list or the create form.
type mode int

const (
	modePicker mode = iota
	modeCreate
)

// tab identifies the active picker tab.
type tab int

const (
	tabActive    tab = 0
	tabResumable tab = 1
	tabTmux      tab = 2
	tabCount         = 3
)

// Model is the Bubble Tea model for the interactive session picker.
type Model struct {
	active    []Entry // live party sessions
	resumable []Entry // stale party sessions
	tmux      []Entry // non-party tmux sessions

	tab      tab
	cursor   [tabCount]int // per-tab cursor position
	width    int
	height   int
	selected string
	quit     bool
	preview  *PreviewData

	mode       mode
	createForm CreateForm
	panePath   string
	startFn    StartFunc
	tmuxStartFn TmuxStartFunc

	store    *state.Store
	client   *tmux.Client
	deleteFn DeleteFunc
	ctx      context.Context
}

// NewModel creates a picker model with the given entries.
func NewModel(ctx context.Context, entries []Entry, tmuxEntries []Entry, store *state.Store, client *tmux.Client, deleteFn DeleteFunc, startFn StartFunc, tmuxStartFn TmuxStartFunc, panePath string) Model {
	active, resumable := splitEntries(entries)

	m := Model{
		active:      active,
		resumable:   resumable,
		tmux:        tmuxEntries,
		store:       store,
		client:      client,
		deleteFn:    deleteFn,
		startFn:     startFn,
		tmuxStartFn: tmuxStartFn,
		panePath:    panePath,
		ctx:         ctx,
	}
	m.tab = m.firstNonEmptyTab()
	return m
}

func (m *Model) firstNonEmptyTab() tab {
	if tabs := m.nonEmptyTabs(); len(tabs) > 0 {
		return tabs[0]
	}
	return tabActive
}

// splitEntries separates entries into active and resumable lists at the IsSep marker.
func splitEntries(entries []Entry) (active, resumable []Entry) {
	inResumable := false
	for _, e := range entries {
		if e.IsSep {
			inResumable = true
			continue
		}
		if inResumable {
			resumable = append(resumable, e)
		} else {
			active = append(active, e)
		}
	}
	return active, resumable
}

// Selected returns the chosen session ID, or empty if cancelled.
func (m Model) Selected() string { return m.selected }

// listForTab returns the entries for a given tab.
func (m *Model) listForTab(t tab) []Entry {
	switch t {
	case tabResumable:
		return m.resumable
	case tabTmux:
		return m.tmux
	default:
		return m.active
	}
}

// currentList returns the entries for the active tab.
func (m *Model) currentList() []Entry {
	return m.listForTab(m.tab)
}

// currentCursor returns a pointer to the active tab's cursor.
func (m *Model) currentCursor() *int {
	return &m.cursor[m.tab]
}

type previewMsg struct {
	tab     tab
	cursor  int
	preview *PreviewData
}

type entriesMsg struct {
	entries []Entry
	tmux    []Entry
}

type deleteMsg struct{}

func (m Model) Init() tea.Cmd {
	return m.loadPreview()
}

func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	if wsMsg, ok := msg.(tea.WindowSizeMsg); ok {
		m.width = wsMsg.Width
		m.height = wsMsg.Height
		return m, nil
	}

	if m.mode == modeCreate {
		return m.updateCreate(msg)
	}

	switch msg := msg.(type) {
	case tea.KeyMsg:
		return m.handleKey(msg)

	case previewMsg:
		if msg.tab == m.tab && msg.cursor == *m.currentCursor() {
			m.preview = msg.preview
		}
		return m, nil

	case deleteMsg:
		return m, m.reloadEntries()

	case entriesMsg:
		m.active, m.resumable = splitEntries(msg.entries)
		m.tmux = msg.tmux
		m.clampCursor()
		return m, m.loadPreview()
	}
	return m, nil
}

func (m Model) handleKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "q", "esc", "ctrl+c":
		m.quit = true
		return m, tea.Quit
	case "enter":
		list := m.currentList()
		cur := *m.currentCursor()
		if cur >= 0 && cur < len(list) {
			m.selected = strings.TrimSpace(list[cur].SessionID)
		}
		return m, tea.Quit
	case "j", "down":
		m.moveCursor(1)
		return m, m.loadPreview()
	case "k", "up":
		m.moveCursor(-1)
		return m, m.loadPreview()
	case "l":
		m.switchTab(true)
		return m, m.loadPreview()
	case "h":
		m.switchTab(false)
		return m, m.loadPreview()
	case "ctrl+d":
		return m, m.deleteCurrent()
	case "n":
		return m.enterCreateMode(false)
	case "N":
		return m.enterCreateMode(true)
	}
	return m, nil
}

func (m Model) enterCreateMode(master bool) (tea.Model, tea.Cmd) {
	isTmux := m.tab == tabTmux
	if isTmux {
		if m.tmuxStartFn == nil {
			return m, nil
		}
	} else {
		if m.startFn == nil {
			return m, nil
		}
	}
	m.mode = modeCreate
	var cmd tea.Cmd
	m.createForm, cmd = NewCreateForm(master, isTmux, m.panePath)
	return m, cmd
}

func (m *Model) switchTab(forward bool) {
	delta := tab(1)
	if !forward {
		delta = tabCount - 1
	}
	m.tab = (m.tab + delta) % tabCount
	m.preview = nil
}

func (m *Model) nonEmptyTabs() []tab {
	var tabs []tab
	for _, t := range []tab{tabActive, tabResumable, tabTmux} {
		if len(m.listForTab(t)) > 0 {
			tabs = append(tabs, t)
		}
	}
	return tabs
}

func (m *Model) moveCursor(delta int) {
	list := m.currentList()
	if len(list) == 0 {
		return
	}
	cur := m.currentCursor()
	*cur += delta
	if *cur < 0 {
		*cur = 0
	}
	if *cur >= len(list) {
		*cur = len(list) - 1
	}
	m.preview = nil
}

func (m *Model) clampCursor() {
	for i := range m.cursor {
		list := m.listForTab(tab(i))
		if m.cursor[i] >= len(list) {
			m.cursor[i] = max(0, len(list)-1)
		}
	}
}

func (m Model) loadPreview() tea.Cmd {
	list := m.currentList()
	cur := *m.currentCursor()
	if cur < 0 || cur >= len(list) {
		return nil
	}
	e := list[cur]
	currentTab, currentCursor := m.tab, cur
	sessionID := strings.TrimSpace(e.SessionID)
	store, client, ctx := m.store, m.client, m.ctx
	return func() tea.Msg {
		pd, _ := BuildPreview(ctx, sessionID, store, client)
		return previewMsg{tab: currentTab, cursor: currentCursor, preview: pd}
	}
}

func (m Model) deleteCurrent() tea.Cmd {
	list := m.currentList()
	cur := *m.currentCursor()
	if cur < 0 || cur >= len(list) {
		return nil
	}
	e := list[cur]
	if strings.Contains(e.Status, "current") {
		return nil
	}
	sessionID := strings.TrimSpace(e.SessionID)
	deleteFn, ctx := m.deleteFn, m.ctx
	return func() tea.Msg {
		_ = deleteFn(ctx, sessionID)
		return deleteMsg{}
	}
}

func (m Model) reloadEntries() tea.Cmd {
	store, client, ctx := m.store, m.client, m.ctx
	return func() tea.Msg {
		entries, _ := BuildEntries(ctx, store, client)
		currentSession, _ := client.CurrentSessionName(ctx)
		tmuxEntries, _ := BuildTmuxEntries(ctx, client, currentSession)
		return entriesMsg{entries: entries, tmux: tmuxEntries}
	}
}

// ---------------------------------------------------------------------------
// View
// ---------------------------------------------------------------------------

const (
	headerHeight = 2 // tab bar + divider
	footerHeight = 1
	dividerWidth = 1
	previewRatio = 40 // percent
	padLeft      = 2  // left margin for content
)

func (m Model) View() string {
	if m.width == 0 || m.height == 0 {
		return ""
	}

	if m.mode == modeCreate {
		return m.createForm.View(m.width, m.height)
	}

	pad := strings.Repeat(" ", padLeft)
	tabBar := pad + m.renderTabBar()
	dividerLine := pickerDividerLineStyle.Render(strings.Repeat("─", m.width))
	footer := pickerFooterStyle.Render(fitToWidth(pad+"⏎ resume  n new  N master  ^d delete  h/l switch  esc quit", m.width))

	bodyH := m.height - headerHeight - footerHeight
	if bodyH < 1 {
		bodyH = 1
	}

	previewW := m.width * previewRatio / 100
	listW := m.width - previewW - dividerWidth

	list := m.renderList(listW, bodyH)
	divider := m.renderVerticalDivider(bodyH)
	preview := m.renderPreview(previewW, bodyH)

	body := lipgloss.JoinHorizontal(lipgloss.Top, list, divider, preview)
	return tabBar + "\n" + dividerLine + "\n" + body + "\n" + footer
}

func (m Model) renderTabBar() string {
	type tabDef struct {
		t     tab
		label string
	}
	tabs := []tabDef{
		{tabActive, fmt.Sprintf(" Active (%d) ", len(m.active))},
		{tabResumable, fmt.Sprintf(" Resumable (%d) ", len(m.resumable))},
		{tabTmux, fmt.Sprintf(" Tmux (%d) ", len(m.tmux))},
	}

	var parts []string
	for _, td := range tabs {
		style := pickerInactiveTabStyle
		if td.t == m.tab {
			style = pickerActiveTabStyle
		}
		parts = append(parts, style.Render(td.label))
	}
	return strings.Join(parts, "  ")
}

func (m Model) renderList(width, height int) string {
	if width < 1 {
		return ""
	}

	list := m.currentList()
	cur := *m.currentCursor()

	var lines []string
	for i, e := range list {
		lines = append(lines, m.renderRow(&e, i == cur, width))
	}

	if len(lines) == 0 {
		empty := strings.Repeat(" ", padLeft) + pickerMutedStyle.Render("No sessions")
		lines = append(lines, fitToWidth(empty, width))
	}

	// Scroll to keep cursor visible.
	start := 0
	if len(lines) > height {
		start = cur - height/2
		if start < 0 {
			start = 0
		}
		if start+height > len(lines) {
			start = len(lines) - height
		}
	}

	visible := lines[start:]
	if len(visible) > height {
		visible = visible[:height]
	}
	for len(visible) < height {
		visible = append(visible, strings.Repeat(" ", width))
	}
	return strings.Join(visible, "\n")
}

func (m Model) renderRow(e *Entry, selected bool, width int) string {
	dot, typeColor := pickerEntryStyle(e)

	id := strings.TrimSpace(e.SessionID)
	title := padRight(truncStr(dash(e.Title), colTitle), colTitle)
	idStr := padRight(truncStr(id, colID), colID)
	typeStr := padRight(truncStr(entryTypeLabel(e), colType), colType)
	cwd := dash(e.Cwd)

	pad := strings.Repeat(" ", padLeft)

	if selected {
		// Tmux-style: full-width reverse-video bar.
		raw := pad + "  " + title + "  " + idStr + "  " + typeStr + "  " + cwd
		return pickerSelectedStyle.Render(fitToWidth(raw, width))
	}

	titleRendered := title
	idRendered := pickerMutedStyle.Render(idStr)
	typeRendered := typeColor.Render(typeStr)
	cwdRendered := pickerCwdStyle.Render(cwd)

	line := pad + dot + titleRendered + "  " + idRendered + "  " + typeRendered + "  " + cwdRendered
	return fitToWidth(line, width)
}

func (m Model) renderPreview(width, height int) string {
	if width < 2 {
		return ""
	}
	content := FormatPreview(m.preview)
	lines := strings.Split(content, "\n")
	if len(lines) > height {
		lines = lines[:height]
	}
	for i, l := range lines {
		lines[i] = fitToWidth(l, width)
	}
	for len(lines) < height {
		lines = append(lines, strings.Repeat(" ", width))
	}
	return strings.Join(lines, "\n")
}

func (m Model) renderVerticalDivider(height int) string {
	ch := pickerVertDividerStyle.Render("│")
	lines := make([]string, height)
	for i := range lines {
		lines[i] = ch
	}
	return strings.Join(lines, "\n")
}

// fitToWidth pads or truncates s to exactly width visual columns.
func fitToWidth(s string, width int) string {
	w := lipgloss.Width(s)
	if w > width {
		return ansi.Truncate(s, width, "")
	}
	if w < width {
		return s + strings.Repeat(" ", width-w)
	}
	return s
}

// ---------------------------------------------------------------------------
// Picker-specific lipgloss styles
// ---------------------------------------------------------------------------

var (
	pickerFooterStyle      = lipgloss.NewStyle().Faint(true)
	pickerDividerLineStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("#2e3440"))
	pickerVertDividerStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("#555555"))
	pickerSelectedStyle    = lipgloss.NewStyle().Reverse(true)
	pickerCwdStyle         = lipgloss.NewStyle().Faint(true)

	pickerActiveTabStyle   = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("4"))
	pickerInactiveTabStyle = lipgloss.NewStyle().Faint(true)

	pickerAccentStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("4"))
	pickerCleanStyle  = lipgloss.NewStyle().Foreground(lipgloss.Color("2"))
	pickerWarnStyle   = lipgloss.NewStyle().Foreground(lipgloss.Color("3"))
	pickerMutedStyle  = lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
	pickerGoldStyle   = lipgloss.NewStyle().Foreground(lipgloss.Color("#ffd700"))
	pickerFaintMuted  = lipgloss.NewStyle().Foreground(lipgloss.Color("8")).Faint(true)
)

// pickerEntryStyle returns the rendered dot and type color for a picker entry.
func pickerEntryStyle(e *Entry) (dot string, typeColor lipgloss.Style) {
	switch {
	case strings.Contains(e.Status, "master"):
		return pickerGoldStyle.Render("● "), pickerGoldStyle
	case strings.Contains(e.Status, "worker"):
		return pickerWarnStyle.Render("│ "), pickerWarnStyle
	case strings.Contains(e.Status, "orphan"):
		return pickerMutedStyle.Render("○ "), pickerMutedStyle
	case strings.Contains(e.Status, "tmux"):
		return pickerAccentStyle.Render("● "), pickerAccentStyle
	case strings.Contains(e.Status, "active"), strings.Contains(e.Status, "current"):
		return pickerCleanStyle.Render("● "), pickerCleanStyle
	default:
		return pickerMutedStyle.Render("○ "), pickerFaintMuted
	}
}
