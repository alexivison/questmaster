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

// tab identifies the active picker tab.
type tab int

const (
	tabActive    tab = 0
	tabResumable tab = 1
)

// Model is the Bubble Tea model for the interactive session picker.
type Model struct {
	active    []Entry // live sessions
	resumable []Entry // stale sessions

	tab     tab
	cursor  [2]int // per-tab cursor position
	width   int
	height  int
	selected string
	quit     bool
	preview  *PreviewData

	store    *state.Store
	client   *tmux.Client
	deleteFn DeleteFunc
	ctx      context.Context
}

// NewModel creates a picker model with the given entries.
func NewModel(ctx context.Context, entries []Entry, store *state.Store, client *tmux.Client, deleteFn DeleteFunc) Model {
	active, resumable := splitEntries(entries)

	startTab := tabActive
	if len(active) == 0 && len(resumable) > 0 {
		startTab = tabResumable
	}

	return Model{
		active:    active,
		resumable: resumable,
		tab:       startTab,
		store:     store,
		client:    client,
		deleteFn:  deleteFn,
		ctx:       ctx,
	}
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

// currentList returns the entries for the active tab.
func (m *Model) currentList() []Entry {
	if m.tab == tabResumable {
		return m.resumable
	}
	return m.active
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
}

type deleteMsg struct{}

func (m Model) Init() tea.Cmd {
	return m.loadPreview()
}

func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		return m, nil

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
		m.clampCursor()
		if len(m.active) == 0 && len(m.resumable) == 0 {
			m.quit = true
			return m, tea.Quit
		}
		// Switch to the other tab if current is now empty.
		if len(m.currentList()) == 0 {
			m.switchTab()
		}
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
	case "tab", "l":
		m.switchTab()
		return m, m.loadPreview()
	case "shift+tab", "h":
		m.switchTab()
		return m, m.loadPreview()
	case "ctrl+d":
		return m, m.deleteCurrent()
	}
	return m, nil
}

func (m *Model) switchTab() {
	if m.tab == tabActive && len(m.resumable) > 0 {
		m.tab = tabResumable
	} else if m.tab == tabResumable && len(m.active) > 0 {
		m.tab = tabActive
	}
	m.preview = nil
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
		var list []Entry
		if tab(i) == tabResumable {
			list = m.resumable
		} else {
			list = m.active
		}
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
		return entriesMsg{entries: entries}
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

	pad := strings.Repeat(" ", padLeft)
	tabBar := pad + m.renderTabBar()
	dividerLine := pickerDividerLineStyle.Render(strings.Repeat("─", m.width))
	footer := pickerFooterStyle.Render(fitToWidth(pad+"⏎ resume  ^d delete  tab switch  esc quit", m.width))

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
	activeLabel := fmt.Sprintf(" Active (%d) ", len(m.active))
	resumableLabel := fmt.Sprintf(" Resumable (%d) ", len(m.resumable))

	var activeTab, resumableTab string
	if m.tab == tabActive {
		activeTab = pickerActiveTabStyle.Render(activeLabel)
		resumableTab = pickerInactiveTabStyle.Render(resumableLabel)
	} else {
		activeTab = pickerInactiveTabStyle.Render(activeLabel)
		resumableTab = pickerActiveTabStyle.Render(resumableLabel)
	}

	return activeTab + "  " + resumableTab
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
	case strings.Contains(e.Status, "active"), strings.Contains(e.Status, "current"):
		return pickerCleanStyle.Render("● "), pickerCleanStyle
	default:
		return pickerMutedStyle.Render("○ "), pickerFaintMuted
	}
}
