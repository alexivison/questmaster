package picker

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/charmbracelet/bubbles/textarea"
	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/alexivison/questmaster/internal/state"
)

// StartFunc creates a questmaster session and returns its ID.
type StartFunc func(ctx context.Context, title, cwd string, opts CreateStartOptions) (string, error)

const (
	labelWidth      = len("Agent:      ")
	maxCompletions  = 8 // max tab-completion suggestions shown
	promptInputRows = 4
)

type createField int

const (
	fieldTitle createField = iota
	fieldDir
	fieldPrimary
	fieldColor
	fieldQuest
	fieldPrompt
)

// CreateStartOptions captures the role selections from the create form.
type CreateStartOptions struct {
	Master       bool
	Primary      string
	DisplayColor string
	Prompt       string
	// QuestID is the active quest to attach on spawn ("" = a free session).
	QuestID string
}

// QuestChoice is an attachable (active) quest offered in the create form. The
// caller supplies only active quests — wip and done are excluded upstream.
type QuestChoice struct {
	ID    string
	Title string
}

// AgentOptions configures the agent selectors shown in the create form.
type AgentOptions struct {
	Available      []string
	DefaultPrimary string
}

// CreateForm handles the new-session creation UI within the picker.
type CreateForm struct {
	titleInput  textinput.Model
	dirInput    textinput.Model
	promptInput textarea.Model
	focus       createField
	master      bool
	submitting  bool     // true after Enter, blocks Esc/input until startFn returns
	completions []string // tab-completion matches (full paths)
	compIndex   int      // cycle index (-1 = common prefix shown, 0..N-1 = cycling)
	recentDirs  []string // recent working directories (raw absolute paths)
	dirListOpen bool     // true while the recents browser is shown
	dirMatches  []string // fuzzy-filtered recents (raw absolute paths)
	dirIndex    int      // selected row in dirMatches
	primaryOpts []string
	primaryIdx  int
	colorOpts   []string
	colorIdx    int
	questOpts   []string // display labels; index 0 is "none"
	questIDs    []string // parallel ids; index 0 is "" (none)
	questIdx    int
	err         string
}

// NewCreateForm creates a form for new session creation.
// initialDir pre-fills the directory input when available.
func NewCreateForm(master bool, initialDir string, agentOptions ...AgentOptions) (CreateForm, tea.Cmd) {
	ti := textinput.New()
	ti.Placeholder = "optional, auto-generated if blank"
	ti.CharLimit = 64
	ti.Prompt = ""
	cmd := ti.Focus()

	di := textinput.New()
	di.Placeholder = "/path/to/project"
	di.CharLimit = 256
	di.Prompt = ""
	if initialDir != "" {
		di.SetValue(initialDir)
		di.SetCursor(len(initialDir))
	}

	pi := textarea.New()
	pi.Placeholder = "optional initial prompt"
	pi.CharLimit = 1024
	pi.Prompt = ""
	pi.ShowLineNumbers = false
	pi.SetHeight(promptInputRows)

	form := CreateForm{
		titleInput:  ti,
		dirInput:    di,
		promptInput: pi,
		master:      master,
	}
	form.initColorOptions()
	if len(agentOptions) > 0 {
		form.initAgentOptions(agentOptions[0], master)
	}

	return form, cmd
}

// Update handles input for the create form.
func (f CreateForm) Update(msg tea.Msg) (CreateForm, tea.Cmd) {
	if keyMsg, ok := msg.(tea.KeyMsg); ok {
		return f.handleKey(keyMsg)
	}
	cmd := f.updateFocusedInput(msg)
	return f, cmd
}

// updateFocusedInput forwards a non-key message to the active text input.
func (f *CreateForm) updateFocusedInput(msg tea.Msg) tea.Cmd {
	var cmd tea.Cmd
	switch f.focus {
	case fieldTitle:
		f.titleInput, cmd = f.titleInput.Update(msg)
	case fieldDir:
		f.dirInput, cmd = f.dirInput.Update(msg)
	case fieldPrompt:
		f.promptInput, cmd = f.promptInput.Update(msg)
	}
	return cmd
}

func (f CreateForm) handleKey(msg tea.KeyMsg) (CreateForm, tea.Cmd) {
	// Block all input while startFn is in-flight (prevents stranding sessions).
	if f.submitting {
		return f, nil
	}

	// The recents browser captures navigation while it is open.
	if f.focus == fieldDir && f.dirListOpen {
		return f.handleDirList(msg)
	}

	isTabOnDir := msg.String() == "tab" && f.focus == fieldDir
	if !isTabOnDir {
		f.completions = nil
		f.compIndex = 0
	}
	f.err = ""

	switch msg.String() {
	case "tab":
		if f.focus == fieldTitle {
			return f, f.moveFocus(1)
		}
		if f.focus == fieldDir {
			f.tabComplete()
			return f, nil
		}
		return f, f.moveFocus(1)
	case "shift+tab":
		return f, f.moveFocus(-1)
	case "up", "ctrl+k":
		return f, f.moveFocus(-1)
	case "down", "ctrl+j":
		return f, f.moveFocus(1)
	case "left", "h":
		if f.focusIsSelector() {
			f.cycleSelection(-1)
			return f, nil
		}
	case "right", "l":
		if f.focusIsSelector() {
			f.cycleSelection(1)
			return f, nil
		}
	case "enter":
		if f.focus == fieldPrompt {
			cmd := f.updateFocusedInput(msg)
			return f, cmd
		}
		return f.submit()
	case "ctrl+s":
		if f.focus == fieldPrompt {
			return f.submit()
		}
	case "ctrl+r":
		if f.focus == fieldDir && len(f.recentDirs) > 0 {
			f.openDirList()
			return f, nil
		}
	case "esc":
		return f, func() tea.Msg { return createCancelMsg{} }
	case "ctrl+c":
		return f, tea.Quit
	}

	if f.focusIsSelector() {
		return f, nil
	}
	cmd := f.updateFocusedInput(msg)
	return f, cmd
}

// focusIsSelector reports whether the focused field is a left/right cycler
// (agent, color, or quest) rather than a text input.
func (f CreateForm) focusIsSelector() bool {
	return f.focus == fieldPrimary || f.focus == fieldColor || f.focus == fieldQuest
}

// handleDirList routes keys while the recents browser is open. Navigation
// keys move within the list; Enter/Tab accept the highlighted directory; Esc
// closes the browser keeping whatever was typed; any other key edits the dir
// input and refilters the list.
func (f CreateForm) handleDirList(msg tea.KeyMsg) (CreateForm, tea.Cmd) {
	f.err = ""
	switch msg.String() {
	case "esc":
		f.closeDirList()
		return f, nil
	case "ctrl+c":
		return f, tea.Quit
	case "up", "ctrl+k":
		f.moveDirSelection(-1)
		return f, nil
	case "down", "ctrl+j":
		f.moveDirSelection(1)
		return f, nil
	case "enter":
		f.acceptDirSelection()
		return f, nil
	case "tab":
		if f.acceptDirSelection() {
			return f, f.moveFocus(1)
		}
		return f, nil
	case "shift+tab":
		f.closeDirList()
		return f, f.moveFocus(-1)
	}
	cmd := f.updateFocusedInput(msg)
	f.refilterDirMatches()
	return f, cmd
}

// openDirList opens the recents browser, seeding the filter from whatever is
// already in the dir input.
func (f *CreateForm) openDirList() {
	f.completions = nil
	f.compIndex = 0
	f.dirListOpen = true
	f.dirIndex = 0
	f.refilterDirMatches()
}

func (f *CreateForm) closeDirList() {
	f.dirListOpen = false
	f.dirMatches = nil
	f.dirIndex = 0
}

// refilterDirMatches re-ranks the recent directories against the current dir
// input. The query is tilde-expanded so a "~/…" value still matches the
// stored absolute paths.
func (f *CreateForm) refilterDirMatches() {
	f.dirMatches = fuzzyRank(expandTilde(f.dirInput.Value()), f.recentDirs)
	if f.dirIndex >= len(f.dirMatches) {
		f.dirIndex = 0
	}
	if f.dirIndex < 0 {
		f.dirIndex = 0
	}
}

func (f *CreateForm) moveDirSelection(delta int) {
	if len(f.dirMatches) == 0 {
		return
	}
	f.dirIndex = wrapIndex(f.dirIndex+delta, len(f.dirMatches))
}

// acceptDirSelection fills the dir input with the highlighted directory and
// closes the browser. It reports whether a selection was applied.
func (f *CreateForm) acceptDirSelection() bool {
	if f.dirIndex < 0 || f.dirIndex >= len(f.dirMatches) {
		f.closeDirList()
		return false
	}
	chosen := shortPath(f.dirMatches[f.dirIndex])
	f.dirInput.SetValue(chosen)
	f.dirInput.SetCursor(len(chosen))
	f.closeDirList()
	return true
}

// ---------------------------------------------------------------------------
// Model integration — create-mode message handling
// ---------------------------------------------------------------------------

func (m Model) updateCreate(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case createCancelMsg:
		m.mode = modePicker
		return m, nil
	case createRequestMsg:
		startFn, ctx := m.startFn, m.ctx
		return m, func() tea.Msg {
			sessionID, err := startFn(ctx, msg.title, msg.dir, msg.opts)
			return createResultMsg{sessionID: sessionID, err: err}
		}
	case createResultMsg:
		m.createForm.submitting = false
		if msg.err != nil {
			m.createForm.err = msg.err.Error()
			return m, nil
		}
		m.selected = msg.sessionID
		return m, tea.Quit
	default:
		var cmd tea.Cmd
		m.createForm, cmd = m.createForm.Update(msg)
		return m, cmd
	}
}

// tabComplete performs zsh-style tab completion on the directory input.
func (f *CreateForm) tabComplete() {
	// Cycle through existing completions on repeated Tab.
	if len(f.completions) > 1 {
		f.compIndex = (f.compIndex + 1) % len(f.completions)
		f.dirInput.SetValue(f.completions[f.compIndex])
		f.dirInput.SetCursor(len(f.completions[f.compIndex]))
		return
	}

	raw := f.dirInput.Value()
	expanded := expandTilde(raw)

	parent, partial := splitDirPartial(expanded)
	matches := listDirMatches(parent, partial)
	if len(matches) == 0 {
		return
	}

	if len(matches) == 1 {
		completed := filepath.Join(parent, matches[0]) + "/"
		completed = shortPath(completed)
		f.dirInput.SetValue(completed)
		f.dirInput.SetCursor(len(completed))
		return
	}

	// Multiple matches: fill common prefix, store matches for cycling.
	common := commonPrefix(matches)
	completed := filepath.Join(parent, common)
	completed = shortPath(completed)
	f.dirInput.SetValue(completed)
	f.dirInput.SetCursor(len(completed))

	f.completions = make([]string, len(matches))
	for i, m := range matches {
		f.completions[i] = shortPath(filepath.Join(parent, m) + "/")
	}
	f.compIndex = -1 // next Tab goes to index 0
}

// View renders the create form.
func (f CreateForm) View(width, height int) string {
	pad := strings.Repeat(" ", padLeft)

	var header string
	switch {
	case f.master:
		header = "New Master Session"
	default:
		header = "New Session"
	}

	inputWidth := width - padLeft - labelWidth
	if inputWidth < 10 {
		inputWidth = 10
	}
	f.titleInput.Width = inputWidth
	f.dirInput.Width = inputWidth
	f.promptInput.SetWidth(inputWidth)

	headerLine := pad + pickerActiveTabStyle.Render(" "+header+" ")
	dividerLine := pickerDividerLineStyle.Render(strings.Repeat("─", width))

	titleLabel := pickerMutedStyle.Render("Title:      ")
	dirLabel := pickerMutedStyle.Render("Dir:        ")
	primaryLabel := pickerMutedStyle.Render("Agent:      ")
	colorLabel := pickerMutedStyle.Render("Color:      ")
	questLabel := pickerMutedStyle.Render("Quest:      ")
	promptLabel := pickerMutedStyle.Render("Prompt:     ")

	var lines []string
	lines = append(lines, headerLine)
	lines = append(lines, dividerLine)
	lines = append(lines, pad+titleLabel+f.titleInput.View())
	lines = append(lines, "")
	lines = append(lines, pad+dirLabel+f.dirInput.View())
	if f.dirListOpen {
		lines = append(lines, f.renderDirList(pad)...)
	}
	if f.hasAgentSelectors() {
		lines = append(lines, "")
		lines = append(lines, pad+primaryLabel+f.renderChoice(f.selectedPrimary(), f.focus == fieldPrimary))
	}
	if f.hasColorSelector() {
		lines = append(lines, "")
		lines = append(lines, pad+colorLabel+f.renderColorChoice(f.selectedColor(), f.focus == fieldColor))
	}
	if f.hasQuestSelector() {
		lines = append(lines, "")
		lines = append(lines, pad+questLabel+f.renderChoice(f.selectedQuestLabel(), f.focus == fieldQuest))
	}
	if f.hasPromptInput() {
		lines = append(lines, "")
		f.promptInput.SetHeight(promptRows(height, len(lines)))
		lines = append(lines, renderLabeledBlock(pad, promptLabel, f.promptInput.View())...)
	}
	lines = append(lines, f.renderCompletions(pad)...)

	if f.err != "" {
		lines = append(lines, "")
		lines = append(lines, pad+pickerWarnStyle.Render(f.err))
	}

	for len(lines) < height-2 {
		lines = append(lines, "")
	}

	lines = append(lines, dividerLine)
	footerText := f.footerText(pad)
	if f.submitting {
		footerText = pad + "Creating session..."
	}
	lines = append(lines, pickerFooterStyle.Render(fitToWidth(footerText, width)))

	return strings.Join(lines, "\n")
}

// renderCompletions renders the tab-completion hints below the dir input.
func (f CreateForm) renderCompletions(pad string) []string {
	if len(f.completions) == 0 {
		return nil
	}
	indent := pad + strings.Repeat(" ", labelWidth)

	// Window completions around the selected item, capped at maxCompletions.
	start, end := 0, len(f.completions)
	if end > maxCompletions {
		// Center the window around the selected item.
		center := f.compIndex
		if center < 0 {
			center = 0
		}
		start = center - maxCompletions/2
		if start < 0 {
			start = 0
		}
		end = start + maxCompletions
		if end > len(f.completions) {
			end = len(f.completions)
			start = end - maxCompletions
		}
	}

	var lines []string
	if start > 0 {
		lines = append(lines, indent+pickerMutedStyle.Render(fmt.Sprintf("  (%d more above)", start)))
	}
	for i := start; i < end; i++ {
		name := filepath.Base(strings.TrimSuffix(f.completions[i], "/")) + "/"
		style := pickerMutedStyle
		prefix := "  "
		if i == f.compIndex {
			style = pickerCleanStyle
			prefix = "> "
		}
		lines = append(lines, indent+style.Render(prefix+name))
	}
	if end < len(f.completions) {
		lines = append(lines, indent+pickerMutedStyle.Render(fmt.Sprintf("  (%d more below)", len(f.completions)-end)))
	}
	return lines
}

// renderDirList renders the recents browser below the dir input, windowed
// around the selected row and capped at maxCompletions.
func (f CreateForm) renderDirList(pad string) []string {
	indent := pad + strings.Repeat(" ", labelWidth)
	if len(f.dirMatches) == 0 {
		return []string{indent + pickerMutedStyle.Render("  no matching directories")}
	}

	start, end := 0, len(f.dirMatches)
	if end > maxCompletions {
		center := f.dirIndex
		start = center - maxCompletions/2
		if start < 0 {
			start = 0
		}
		end = start + maxCompletions
		if end > len(f.dirMatches) {
			end = len(f.dirMatches)
			start = end - maxCompletions
		}
	}

	var lines []string
	if start > 0 {
		lines = append(lines, indent+pickerMutedStyle.Render(fmt.Sprintf("  (%d more above)", start)))
	}
	for i := start; i < end; i++ {
		label := shortPath(f.dirMatches[i])
		style := pickerMutedStyle
		prefix := "  "
		if i == f.dirIndex {
			style = pickerCleanStyle
			prefix = "> "
		}
		lines = append(lines, indent+style.Render(prefix+label))
	}
	if end < len(f.dirMatches) {
		lines = append(lines, indent+pickerMutedStyle.Render(fmt.Sprintf("  (%d more below)", len(f.dirMatches)-end)))
	}
	return lines
}

func (f CreateForm) submit() (CreateForm, tea.Cmd) {
	raw := f.dirInput.Value()
	var dir string
	var errMsg string
	dir, errMsg = validateDir(raw)
	if errMsg != "" {
		f.err = errMsg
		return f, nil
	}
	opts := CreateStartOptions{Master: f.master}
	if f.hasAgentSelectors() {
		opts.Primary = f.selectedPrimary()
	}
	if f.hasColorSelector() {
		opts.DisplayColor = f.selectedColor()
	}
	if f.hasQuestSelector() {
		opts.QuestID = f.selectedQuestID()
	}
	if f.hasPromptInput() {
		opts.Prompt = strings.TrimSpace(f.promptInput.Value())
	}
	f.submitting = true
	return f, func() tea.Msg {
		return createRequestMsg{title: f.titleInput.Value(), dir: dir, opts: opts}
	}
}

func (f CreateForm) footerText(pad string) string {
	if f.focus == fieldDir && f.dirListOpen {
		return pad + "↑↓ pick  ⏎ use  tab use+next  esc close"
	}
	if f.focus == fieldDir && len(f.recentDirs) > 0 {
		return pad + "⏎ create  ^j/^k/↑↓ field  tab complete  ^r recents  esc back"
	}
	if f.focus == fieldPrompt {
		return pad + "^s create  ⏎ newline  ^j/^k/↑↓ field  esc back"
	}
	if f.hasChoiceSelectors() {
		return pad + "⏎ create  ^j/^k/↑↓ field  ←→/h/l select  tab complete  esc back"
	}
	return pad + "⏎ create  ^j/^k/↑↓ field  tab complete  esc back"
}

func promptRows(height, usedContentRows int) int {
	rows := promptInputRows
	available := height - 2 - usedContentRows
	if available < rows {
		rows = available
	}
	if rows < 1 {
		return 1
	}
	return rows
}

func renderLabeledBlock(pad, label, block string) []string {
	blockLines := strings.Split(block, "\n")
	if len(blockLines) == 0 {
		return []string{pad + label}
	}

	lines := []string{pad + label + blockLines[0]}
	indent := pad + strings.Repeat(" ", labelWidth)
	for _, line := range blockLines[1:] {
		lines = append(lines, indent+line)
	}
	return lines
}

func (f *CreateForm) initAgentOptions(opts AgentOptions, master bool) {
	available := append([]string(nil), opts.Available...)
	if opts.DefaultPrimary != "" && !containsString(available, opts.DefaultPrimary) {
		available = append(available, opts.DefaultPrimary)
	}
	if len(available) == 0 {
		return
	}

	f.primaryOpts = available
	f.primaryIdx = indexOrZero(f.primaryOpts, opts.DefaultPrimary)
}

func (f *CreateForm) initColorOptions() {
	f.colorOpts = append([]string{""}, state.DisplayColorOptions()...)
	f.colorIdx = 0
}

func (f CreateForm) hasAgentSelectors() bool {
	return len(f.primaryOpts) > 0
}

func (f CreateForm) hasColorSelector() bool {
	return len(f.colorOpts) > 0
}

func (f CreateForm) hasChoiceSelectors() bool {
	return f.hasAgentSelectors() || f.hasColorSelector() || f.hasQuestSelector()
}

func (f CreateForm) hasQuestSelector() bool { return len(f.questIDs) > 0 }

// initQuestOptions seeds the quest selector with "none" plus each active quest.
// With no active quests the selector is omitted entirely.
func (f *CreateForm) initQuestOptions(choices []QuestChoice) {
	if len(choices) == 0 {
		return
	}
	f.questOpts = []string{"none"}
	f.questIDs = []string{""}
	for _, c := range choices {
		label := c.ID
		if c.Title != "" {
			label = c.ID + " — " + c.Title
		}
		f.questOpts = append(f.questOpts, label)
		f.questIDs = append(f.questIDs, c.ID)
	}
	f.questIdx = 0
}

func (f CreateForm) selectedQuestID() string {
	if f.questIdx < 0 || f.questIdx >= len(f.questIDs) {
		return ""
	}
	return f.questIDs[f.questIdx]
}

func (f CreateForm) selectedQuestLabel() string {
	if f.questIdx < 0 || f.questIdx >= len(f.questOpts) {
		return "none"
	}
	return f.questOpts[f.questIdx]
}

// hasPromptInput reports whether the prompt field is shown.
func (f CreateForm) hasPromptInput() bool {
	return true
}

func (f *CreateForm) moveFocus(delta int) tea.Cmd {
	fields := f.fieldOrder()
	if len(fields) == 0 {
		return nil
	}

	idx := 0
	for i, field := range fields {
		if field == f.focus {
			idx = i
			break
		}
	}

	next := idx + delta
	if next < 0 {
		next = 0
	}
	if next >= len(fields) {
		next = len(fields) - 1
	}
	return f.setFocus(fields[next])
}

func (f CreateForm) fieldOrder() []createField {
	fields := []createField{fieldTitle, fieldDir}
	if f.hasAgentSelectors() {
		fields = append(fields, fieldPrimary)
	}
	if f.hasColorSelector() {
		fields = append(fields, fieldColor)
	}
	if f.hasQuestSelector() {
		fields = append(fields, fieldQuest)
	}
	if f.hasPromptInput() {
		fields = append(fields, fieldPrompt)
	}
	return fields
}

func (f *CreateForm) setFocus(next createField) tea.Cmd {
	if f.focus == fieldDir && next != fieldDir {
		f.closeDirList()
	}
	switch f.focus {
	case fieldTitle:
		f.titleInput.Blur()
	case fieldDir:
		f.dirInput.Blur()
	case fieldPrompt:
		f.promptInput.Blur()
	}

	f.focus = next
	switch next {
	case fieldTitle:
		return f.titleInput.Focus()
	case fieldDir:
		return f.dirInput.Focus()
	case fieldPrompt:
		return f.promptInput.Focus()
	default:
		return nil
	}
}

func (f *CreateForm) cycleSelection(delta int) {
	switch f.focus {
	case fieldPrimary:
		if len(f.primaryOpts) == 0 {
			return
		}
		f.primaryIdx = wrapIndex(f.primaryIdx+delta, len(f.primaryOpts))
	case fieldColor:
		if len(f.colorOpts) == 0 {
			return
		}
		f.colorIdx = wrapIndex(f.colorIdx+delta, len(f.colorOpts))
	case fieldQuest:
		if len(f.questOpts) == 0 {
			return
		}
		f.questIdx = wrapIndex(f.questIdx+delta, len(f.questOpts))
	}
}

func (f CreateForm) selectedPrimary() string {
	if len(f.primaryOpts) == 0 || f.primaryIdx < 0 || f.primaryIdx >= len(f.primaryOpts) {
		return ""
	}
	return f.primaryOpts[f.primaryIdx]
}

func (f CreateForm) selectedColor() string {
	if len(f.colorOpts) == 0 || f.colorIdx < 0 || f.colorIdx >= len(f.colorOpts) {
		return ""
	}
	return f.colorOpts[f.colorIdx]
}

func (f CreateForm) renderChoice(value string, focused bool) string {
	label := value
	if label == "" {
		label = "none"
	}
	choice := "[ " + label + " ]"
	if focused {
		return pickerAccentStyle.Render(choice)
	}
	return choice
}

func (f CreateForm) renderColorChoice(value string, focused bool) string {
	if strings.TrimSpace(value) == "" {
		if focused {
			return pickerAccentStyle.Render("[ none ]")
		}
		return "[ none ]"
	}
	label := state.NormalizeDisplayColor(value)
	swatch := lipgloss.NewStyle().Foreground(pickerDisplayColor(label)).Render("■")
	if focused {
		return pickerAccentStyle.Render("[ ") + swatch + pickerAccentStyle.Render(" "+label+" ]")
	}
	return "[ " + swatch + " " + label + " ]"
}

func pickerDisplayColor(color string) lipgloss.Color {
	switch state.NormalizeDisplayColor(color) {
	case "green":
		return lipgloss.Color("2")
	case "yellow":
		return lipgloss.Color("3")
	case "magenta":
		return lipgloss.Color("5")
	case "cyan":
		return lipgloss.Color("6")
	case "red":
		return lipgloss.Color("1")
	default:
		return lipgloss.Color("4")
	}
}

// ---------------------------------------------------------------------------
// Messages
// ---------------------------------------------------------------------------

type createRequestMsg struct {
	title string
	dir   string
	opts  CreateStartOptions
}

type createCancelMsg struct{}

type createResultMsg struct {
	sessionID string
	err       error
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// validateDir expands tilde and checks the path is an existing directory.
// Returns the resolved path and an empty error string on success.
func validateDir(raw string) (string, string) {
	dir := expandTilde(raw)
	if dir == "" {
		return "", "directory is required"
	}
	info, err := os.Stat(dir)
	if err != nil || !info.IsDir() {
		return "", "directory does not exist"
	}
	return dir, ""
}

func expandTilde(path string) string {
	if strings.HasPrefix(path, "~/") || path == "~" {
		home, _ := os.UserHomeDir()
		if home != "" {
			return home + path[1:]
		}
	}
	return path
}

func splitDirPartial(path string) (parent, partial string) {
	if strings.HasSuffix(path, "/") || path == "" {
		return path, ""
	}
	return filepath.Dir(path), filepath.Base(path)
}

func listDirMatches(parent, prefix string) []string {
	if parent == "" {
		parent = "."
	}
	entries, err := os.ReadDir(parent)
	if err != nil {
		return nil
	}
	var matches []string
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		if strings.HasPrefix(e.Name(), prefix) {
			matches = append(matches, e.Name())
		}
	}
	sort.Strings(matches)
	return matches
}

func commonPrefix(strs []string) string {
	if len(strs) == 0 {
		return ""
	}
	prefix := strs[0]
	for _, s := range strs[1:] {
		for !strings.HasPrefix(s, prefix) {
			prefix = prefix[:len(prefix)-1]
			if prefix == "" {
				return ""
			}
		}
	}
	return prefix
}

func containsString(values []string, target string) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}

func indexOrZero(values []string, target string) int {
	for i, value := range values {
		if value == target {
			return i
		}
	}
	return 0
}

func wrapIndex(idx, length int) int {
	if length == 0 {
		return 0
	}
	if idx < 0 {
		return length - 1
	}
	if idx >= length {
		return 0
	}
	return idx
}
