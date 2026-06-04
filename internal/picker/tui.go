package picker

import (
	"context"
	"fmt"
	"os"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"

	"github.com/alexivison/questmaster/internal/palette"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
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
	tabCount         = 2
)

// Model is the Bubble Tea model for the interactive session picker.
type Model struct {
	active    []Entry // live questmaster sessions
	resumable []Entry // stale questmaster sessions

	tab      tab
	cursor   [tabCount]int // per-tab cursor position
	width    int
	height   int
	selected string
	quit     bool

	mode         mode
	createForm   CreateForm
	agentOpts    AgentOptions
	questChoices []QuestChoice
	recentDirs   []string
	startFn      StartFunc

	store    *state.Store
	client   *tmux.Client
	deleteFn DeleteFunc
	ctx      context.Context
}

// NewModel creates a picker model with the given entries. questChoices are the
// active quests offered in the create form (nil for none).
func NewModel(ctx context.Context, entries []Entry, store *state.Store, client *tmux.Client, deleteFn DeleteFunc, startFn StartFunc, agentOpts AgentOptions, questChoices []QuestChoice) Model {
	active, resumable := splitEntries(entries)

	m := Model{
		active:       active,
		resumable:    resumable,
		agentOpts:    agentOpts,
		questChoices: questChoices,
		recentDirs:   RecentDirs(store, recentDirsLimit),
		store:        store,
		client:       client,
		deleteFn:     deleteFn,
		startFn:      startFn,
		ctx:          ctx,
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

type entriesMsg struct {
	entries []Entry
}

type deleteMsg struct{}

func (m Model) Init() tea.Cmd {
	return nil
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

	case deleteMsg:
		return m, m.reloadEntries()

	case entriesMsg:
		m.active, m.resumable = splitEntries(msg.entries)
		m.clampCursor()
		return m, nil
	}
	return m, nil
}

func (m Model) handleKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	key := msg.String()
	if len(key) == 1 && key[0] >= '1' && key[0] <= '9' {
		if !m.moveCursorTo(int(key[0] - '1')) {
			return m, nil
		}
		m.selectCurrent()
		return m, tea.Quit
	}

	switch key {
	case "q", "esc", "ctrl+c":
		m.quit = true
		return m, tea.Quit
	case "enter":
		m.selectCurrent()
		return m, tea.Quit
	case "j", "down":
		m.moveCursor(1)
		return m, nil
	case "k", "up":
		m.moveCursor(-1)
		return m, nil
	case "l":
		m.switchTab(true)
		return m, nil
	case "h":
		m.switchTab(false)
		return m, nil
	case "ctrl+d":
		cmd := m.deleteCurrent()
		if cmd == nil {
			return m, nil
		}
		return m, cmd
	case "n":
		return m.enterCreateMode(false)
	case "m", "N":
		return m.enterCreateMode(true)
	}
	return m, nil
}

func (m *Model) selectCurrent() {
	list := m.currentList()
	cur := *m.currentCursor()
	if cur < 0 || cur >= len(list) {
		return
	}
	m.selected = strings.TrimSpace(list[cur].SessionID)
}

func (m Model) enterCreateMode(master bool) (tea.Model, tea.Cmd) {
	if m.startFn == nil {
		return m, nil
	}
	m.mode = modeCreate
	var cmd tea.Cmd
	initialDir, _ := os.Getwd()
	m.createForm, cmd = NewCreateForm(master, initialDir, m.agentOpts)
	m.createForm.recentDirs = m.recentDirs
	m.createForm.initQuestOptions(m.questChoices)
	return m, cmd
}

func (m *Model) switchTab(forward bool) {
	delta := tab(1)
	if !forward {
		delta = tabCount - 1
	}
	m.tab = (m.tab + delta) % tabCount
}

func (m *Model) nonEmptyTabs() []tab {
	var tabs []tab
	for _, t := range []tab{tabActive, tabResumable} {
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
}

func (m *Model) moveCursorTo(index int) bool {
	if index < 0 || index >= len(m.currentList()) {
		return false
	}
	m.moveCursor(index - *m.currentCursor())
	return true
}

func (m *Model) clampCursor() {
	for i := range m.cursor {
		listLen := len(m.listForTab(tab(i)))
		switch {
		case listLen == 0:
			m.cursor[i] = 0
		case m.cursor[i] >= listLen:
			m.cursor[i] = listLen - 1
		case m.cursor[i] < 0:
			m.cursor[i] = 0
		}
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
		return entriesMsg{entries: entries}
	}
}

// ---------------------------------------------------------------------------
// View
// ---------------------------------------------------------------------------

const (
	headerHeight = 2 // tab bar + divider
	footerHeight = 2 // divider + footer text
	padLeft      = 2 // left margin for content

	// recentDirsLimit caps how many recent working directories the create
	// form offers in its recents browser.
	recentDirsLimit = 20
)

func (m Model) View() string {
	if m.width == 0 || m.height == 0 {
		return ""
	}

	if m.mode == modeCreate {
		return m.createForm.View(m.width, m.height)
	}

	contentW := m.width
	pad := strings.Repeat(" ", padLeft)
	tabBar := fitToWidth(pad+m.renderTabBar(), contentW)
	dividerLine := pickerDividerLineStyle.Render(strings.Repeat("─", contentW))
	footer := pickerFooterStyle.Render(fitToWidth(pad+"⏎ resume  n new  m/N master  ^d delete  h/l switch  esc quit", contentW))

	bodyH := m.height - headerHeight - footerHeight
	if bodyH < 1 {
		bodyH = 1
	}

	body := m.renderList(contentW, bodyH)
	return tabBar + "\n" + dividerLine + "\n" + body + "\n" + dividerLine + "\n" + footer
}

func (m Model) renderTabBar() string {
	type tabDef struct {
		t     tab
		label string
	}
	tabs := []tabDef{
		{tabActive, fmt.Sprintf(" Active (%d) ", len(m.active))},
		{tabResumable, fmt.Sprintf(" Resumable (%d) ", len(m.resumable))},
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
	cursorStart := 0
	cursorEnd := 0
	for i := range list {
		var next *Entry
		if i+1 < len(list) {
			next = &list[i+1]
		}
		if i == cur {
			cursorStart = len(lines)
		}
		rowLines := strings.Split(m.renderRow(&list[i], next, i, i == cur, width), "\n")
		lines = append(lines, rowLines...)
		if i == cur {
			cursorEnd = len(lines)
		}
	}

	if len(lines) == 0 {
		empty := strings.Repeat(" ", padLeft) + pickerMutedStyle.Render("No sessions")
		lines = append(lines, fitToWidth(empty, width))
	}

	// Scroll to keep cursor visible.
	start := 0
	if len(lines) > height {
		start = cursorStart - height/2
		if start < 0 {
			start = 0
		}
		if cursorEnd > start+height {
			start = cursorEnd - height
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

func (m Model) renderRow(e *Entry, next *Entry, index int, selected bool, width int) string {
	rawGlyph, styledGlyph := entryGlyph(e, next)

	id := strings.TrimSpace(e.SessionID)
	cwd := dash(e.Cwd)

	pad := strings.Repeat(" ", padLeft)
	metaPrefixRaw, metaPrefixStyled := metadataPrefix(e, next)
	idText := sessionRoleIcon(e) + " " + id
	pathText := "\uf114 " + cwd

	// Slow-moving info (creation date, uptime) right-aligned on the title line.
	// The title column fills the remaining width; the info is dropped when the
	// row is too narrow to keep a usable title.
	info := rowMetadata(e, time.Now())
	titleColW := width - padLeft - lipgloss.Width(rawGlyph)
	if info != "" {
		reserved := lipgloss.Width(info) + 1 // +1 separator column
		if titleColW-reserved >= minTitleColW {
			titleColW -= reserved
		} else {
			info = ""
		}
	}
	if titleColW < 0 {
		titleColW = 0
	}

	if selected {
		titleLine := pickerSelectedStyle.Render(pad+rawGlyph) +
			selectedTitleCell(e.Title, e.PrimaryAgent, titleColW)
		if info != "" {
			titleLine += pickerSelectedStyle.Render(" ") +
				pickerSelectedStyle.Inherit(pickerMutedStyle).Render(info)
		}
		metaLine := pickerSelectedStyle.Render(pad+metaPrefixRaw) +
			pickerSelectedStyle.Inherit(pickerMutedStyle).Render(idText) +
			pickerSelectedStyle.Render("  ") +
			pickerSelectedStyle.Inherit(pickerCwdStyle).Render(pathText)
		return fitSelectedToWidth(titleLine, width) + "\n" + fitSelectedToWidth(metaLine, width)
	}

	_, styledTitle := titleCells(e.Title, e.PrimaryAgent, titleColW)
	titleLine := pad + styledGlyph + styledTitle
	if info != "" {
		titleLine += " " + pickerMutedStyle.Render(info)
	}
	metaLine := pad + metaPrefixStyled + pickerMutedStyle.Render(idText) + "  " + pickerCwdStyle.Render(pathText)
	return fitToWidth(titleLine, width) + "\n" + fitToWidth(metaLine, width)
}

// rowMetadata returns the slow-moving session info shown on the right of a
// picker title line: the creation date for every session, plus uptime for live
// ones. Empty when the entry carries no usable timestamps.
func rowMetadata(e *Entry, now time.Time) string {
	var parts []string
	if created := formatRowDate(e.CreatedAt); created != "" {
		parts = append(parts, created)
	}
	if e.Live {
		if up := formatUptime(e.LastStartedAt, now); up != "" {
			parts = append(parts, "up "+up)
		}
	}
	return strings.Join(parts, " \u00b7 ")
}

// formatRowDate renders an RFC3339 timestamp as a zero-padded MM/DD date,
// matching the shortTS convention used for resumable-session dates, or ""
// when the timestamp is missing or unparseable.
func formatRowDate(ts string) string {
	t, err := time.Parse(time.RFC3339, ts)
	if err != nil {
		return ""
	}
	return t.Format("01/02")
}

// formatUptime renders the elapsed time since start as a compact duration
// (s/m/h/d), or "" when start is missing, unparseable, or in the future.
func formatUptime(start string, now time.Time) string {
	t, err := time.Parse(time.RFC3339, start)
	if err != nil {
		return ""
	}
	d := now.Sub(t)
	switch {
	case d < 0:
		return ""
	case d < time.Minute:
		return fmt.Sprintf("%ds", int(d.Seconds()))
	case d < time.Hour:
		return fmt.Sprintf("%dm", int(d.Minutes()))
	case d < 24*time.Hour:
		return fmt.Sprintf("%dh", int(d.Hours()))
	default:
		return fmt.Sprintf("%dd", int(d.Hours()/24))
	}
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

func fitSelectedToWidth(s string, width int) string {
	w := lipgloss.Width(s)
	if w > width {
		return ansi.Truncate(s, width, "")
	}
	if w < width {
		return s + pickerSelectedStyle.Width(width-w).Render("")
	}
	return s
}

// ---------------------------------------------------------------------------
// Picker-specific lipgloss styles
// ---------------------------------------------------------------------------

var (
	pickerFooterStyle      = lipgloss.NewStyle().Faint(true)
	pickerDividerLineStyle = lipgloss.NewStyle().Foreground(palette.DividerFg)
	pickerSelectedStyle    = lipgloss.NewStyle().Background(palette.SelectedRowBg)
	pickerCwdStyle         = lipgloss.NewStyle().Faint(true)

	pickerActiveTabStyle   = lipgloss.NewStyle().Bold(true).Foreground(palette.Accent)
	pickerInactiveTabStyle = lipgloss.NewStyle().Faint(true)

	pickerAccentStyle     = lipgloss.NewStyle().Foreground(palette.Accent)
	pickerCleanStyle      = lipgloss.NewStyle().Foreground(palette.StandaloneRole)
	pickerWarnStyle       = lipgloss.NewStyle().Foreground(palette.WorkerRole)
	pickerMutedStyle      = lipgloss.NewStyle().Foreground(palette.Muted)
	pickerTreeGutterStyle = lipgloss.NewStyle().Foreground(palette.DividerBorder)
)

// entryGlyph returns the leading glyph for a picker entry: raw text for the
// selected row and the rendered version for unselected rows. Worker rows keep
// tree connectors that depend on the next entry.
func entryGlyph(e *Entry, next *Entry) (raw string, styled string) {
	switch {
	case strings.Contains(e.Status, "master"):
		return "", ""
	case strings.Contains(e.Status, "orphan"):
		return "○ ", pickerMutedStyle.Render("○ ")
	case strings.Contains(e.Status, "worker"):
		raw := workerConnector(next)
		return raw, pickerTreeGutterStyle.Render(raw)
	case strings.Contains(e.Status, "active"), strings.Contains(e.Status, "current"):
		return "", ""
	default:
		return "○ ", pickerMutedStyle.Render("○ ")
	}
}

func metadataPrefix(e *Entry, next *Entry) (raw string, styled string) {
	if !strings.Contains(e.Status, "worker") || strings.Contains(e.Status, "orphan") {
		return "", ""
	}
	raw = workerContinuation(next)
	if strings.TrimSpace(raw) == "" {
		return raw, raw
	}
	return raw, pickerTreeGutterStyle.Render(raw)
}

func sessionRoleIcon(e *Entry) string {
	switch entrySessionType(e) {
	case "master":
		return "⚔"
	case "worker":
		return "⚒"
	default:
		return "✠"
	}
}

func entrySessionType(e *Entry) string {
	if e.SessionType != "" {
		return e.SessionType
	}
	switch {
	case strings.Contains(e.Status, "master"):
		return "master"
	case strings.Contains(e.Status, "worker"):
		return "worker"
	default:
		return "standalone"
	}
}

// titleCells lays out the agent icon and title within colWidth visual columns,
// padding short titles and truncating long ones so the row fills the container.
func titleCells(title, agent string, colWidth int) (raw string, styled string) {
	if colWidth < 0 {
		colWidth = 0
	}
	icon := pickerAgentIcon(agent)
	if icon == "" {
		cell := padRight(truncStr(dash(title), colWidth), colWidth)
		return cell, cell
	}

	titleWidth := colWidth - lipgloss.Width(icon) - 1
	if titleWidth < 0 {
		titleWidth = 0
	}
	titleText := ""
	if titleWidth > 0 {
		titleText = padRight(truncStr(dash(title), titleWidth), titleWidth)
	}

	raw = icon + " " + titleText
	styled = pickerAgentIconStyle(agent).Render(icon) + " " + titleText
	return raw, styled
}

func selectedTitleCell(title, agent string, colWidth int) string {
	if colWidth < 0 {
		colWidth = 0
	}
	icon := pickerAgentIcon(agent)
	if icon == "" {
		raw, _ := titleCells(title, agent, colWidth)
		return pickerSelectedStyle.Render(raw)
	}

	titleWidth := colWidth - lipgloss.Width(icon) - 1
	if titleWidth < 0 {
		titleWidth = 0
	}
	titleText := ""
	if titleWidth > 0 {
		titleText = padRight(truncStr(dash(title), titleWidth), titleWidth)
	}

	return pickerSelectedStyle.Inherit(pickerAgentIconStyle(agent)).Render(icon) +
		pickerSelectedStyle.Render(" "+titleText)
}

func pickerAgentIcon(agent string) string {
	switch agent {
	case "codex":
		return "\uf44f"
	case "claude":
		return "\U000f06c4"
	case "pi":
		return "\u03c0"
	case "omp":
		return "\u03c9"
	default:
		return ""
	}
}

func pickerAgentIconStyle(agent string) lipgloss.Style {
	switch agent {
	case "claude":
		return lipgloss.NewStyle().Foreground(palette.ClaudeColor)
	case "codex":
		return lipgloss.NewStyle().Foreground(palette.CodexColor)
	case "pi":
		return lipgloss.NewStyle().Foreground(palette.PiColor)
	case "omp":
		return lipgloss.NewStyle().Foreground(palette.OmpColor)
	default:
		return pickerMutedStyle
	}
}

// workerConnector picks the tree branch shape for a worker row based on
// whether another worker of the same group follows it.
func workerConnector(next *Entry) string {
	if next != nil && strings.Contains(next.Status, "worker") && !strings.Contains(next.Status, "orphan") {
		return "┣━ "
	}
	return "┗━ "
}

func workerContinuation(next *Entry) string {
	if next != nil && strings.Contains(next.Status, "worker") && !strings.Contains(next.Status, "orphan") {
		return "┃  "
	}
	return "   "
}
