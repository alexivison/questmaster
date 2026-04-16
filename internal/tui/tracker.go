package tui

import (
	"context"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"

	"github.com/anthropics/ai-party/tools/party-cli/internal/state"
)

// trackerMode is the input mode for the unified tracker.
type trackerMode int

const (
	trackerModeNormal trackerMode = iota
	trackerModeRelay
	trackerModeBroadcast
	trackerModeSpawn
	trackerModeManifest
)

// SessionRow is the display-ready session data for the tracker.
type SessionRow struct {
	ID               string
	Title            string
	Cwd              string
	PrimaryAgent     string
	Status           string // "active" or "stopped"
	SessionType      string // "master", "worker", or "standalone"
	ParentID         string
	WorkerCount      int
	HasCompanion     bool
	PrimaryState     string
	CompanionState   string
	CompanionVerdict string
	Stage            string
	Snippet          string
	IsCurrent        bool
}

// Primary state dot indicators.
const (
	PrimaryStateDotActive  = "▸"
	PrimaryStateDotWaiting = "◐"
	PrimaryStateDotIdle    = "◌"
	PrimaryStateDotDone    = "✔"
)

// TrackerSnapshot is the full rendered data set for one refresh tick.
type TrackerSnapshot struct {
	Sessions []SessionRow
	Current  CurrentSessionDetail
}

// CurrentSessionDetail is the expanded detail block for the running session.
type CurrentSessionDetail struct {
	ID               string
	Title            string
	SessionType      string
	Cwd              string
	WorkerCount      int
	PrimaryAgent     string
	PrimaryState     string
	CompanionName    string
	CompanionStatus  CompanionStatus
	CompanionSnippet string
	Evidence         []EvidenceEntry
}

// SessionFetcher loads all session data for the tracker.
type SessionFetcher func(current SessionInfo) (TrackerSnapshot, error)

// TrackerModel is the Bubble Tea sub-model for the unified tracker view.
type TrackerModel struct {
	current  SessionInfo
	sessions []SessionRow
	detail   CurrentSessionDetail
	cursor   int
	mode     trackerMode
	input    textinput.Model
	width    int
	height   int
	lastErr  error

	manifestJSON string
	manifestID   string
	manifestScrl int

	fetcher SessionFetcher
	actions TrackerActions
}

// NewTrackerModel creates a tracker with injected dependencies.
func NewTrackerModel(current SessionInfo, fetcher SessionFetcher, actions TrackerActions) TrackerModel {
	ti := textinput.New()
	ti.CharLimit = 500
	ti.Width = 60

	return TrackerModel{
		current: current,
		fetcher: fetcher,
		actions: actions,
		input:   ti,
	}
}

// SetCurrent updates the running session metadata.
func (tm *TrackerModel) SetCurrent(current SessionInfo) {
	tm.current = current
}

// refreshSessions reloads the session list and clamps the cursor.
func (tm *TrackerModel) refreshSessions() {
	if tm.fetcher == nil {
		return
	}

	selectedID := ""
	if row, ok := tm.selectedSession(); ok {
		selectedID = row.ID
	}

	snapshot, err := tm.fetcher(tm.current)
	if err != nil {
		tm.lastErr = err
		return
	}

	tm.sessions = snapshot.Sessions
	tm.detail = snapshot.Current
	tm.lastErr = nil

	tm.cursor = 0
	if idx := tm.indexOfSession(selectedID); selectedID != "" && idx >= 0 {
		tm.cursor = idx
	} else if idx := tm.indexOfSession(tm.current.ID); tm.current.ID != "" && idx >= 0 {
		tm.cursor = idx
	}

	if tm.cursor < 0 {
		tm.cursor = 0
	}
	if tm.cursor >= len(tm.sessions) {
		tm.cursor = max(0, len(tm.sessions)-1)
	}
}

// Update handles key messages for the tracker sub-model.
func (tm TrackerModel) Update(msg tea.Msg) (TrackerModel, tea.Cmd) {
	keyMsg, ok := msg.(tea.KeyMsg)
	if !ok {
		return tm, nil
	}

	if tm.mode == trackerModeManifest {
		return tm.updateManifest(keyMsg)
	}
	if tm.mode != trackerModeNormal {
		return tm.updateInput(keyMsg)
	}
	return tm.updateNormal(keyMsg)
}

func (tm TrackerModel) updateNormal(msg tea.KeyMsg) (TrackerModel, tea.Cmd) {
	ctx := context.Background()
	tm.lastErr = nil

	switch msg.String() {
	case "q", "ctrl+c":
		return tm, tea.Quit

	case "j", "down":
		if tm.cursor < len(tm.sessions)-1 {
			tm.cursor++
		}

	case "k", "up":
		if tm.cursor > 0 {
			tm.cursor--
		}

	case "enter":
		if row, ok := tm.selectedSession(); ok && row.Status == "active" && tm.actions != nil {
			tm.lastErr = tm.actions.Attach(ctx, tm.current.ID, row.ID)
			tm.refreshSessions()
		}

	case "r":
		if row, ok := tm.selectedManagedWorker(); ok {
			tm.mode = trackerModeRelay
			tm.input.Placeholder = fmt.Sprintf("message to %s...", row.ID)
			tm.input.Reset()
			tm.input.Focus()
			return tm, textinput.Blink
		}

	case "b":
		if tm.currentIsMaster() {
			tm.mode = trackerModeBroadcast
			tm.input.Placeholder = "broadcast to current workers..."
			tm.input.Reset()
			tm.input.Focus()
			return tm, textinput.Blink
		}

	case "s":
		if tm.currentIsMaster() {
			tm.mode = trackerModeSpawn
			tm.input.Placeholder = "worker title..."
			tm.input.Reset()
			tm.input.Focus()
			return tm, textinput.Blink
		}

	case "x":
		if row, ok := tm.selectedSession(); ok && tm.actions != nil {
			tm.lastErr = tm.actions.Stop(ctx, row.ParentID, row.ID)
			tm.refreshSessions()
		}

	case "d":
		if row, ok := tm.selectedSession(); ok && tm.actions != nil {
			tm.lastErr = tm.actions.Delete(ctx, row.ParentID, row.ID)
			tm.refreshSessions()
		}

	case "m":
		if row, ok := tm.selectedSession(); ok && tm.actions != nil {
			j, err := tm.actions.ManifestJSON(row.ID)
			if err != nil {
				tm.lastErr = err
			} else {
				tm.mode = trackerModeManifest
				tm.manifestJSON = j
				tm.manifestID = row.ID
				tm.manifestScrl = 0
			}
		}
	}

	return tm, nil
}

func (tm TrackerModel) updateInput(msg tea.KeyMsg) (TrackerModel, tea.Cmd) {
	switch msg.String() {
	case "esc":
		tm.mode = trackerModeNormal
		tm.input.Blur()
		return tm, nil

	case "enter":
		ctx := context.Background()
		val := tm.input.Value()
		if val != "" && tm.actions != nil {
			switch tm.mode {
			case trackerModeRelay:
				if row, ok := tm.selectedManagedWorker(); ok {
					tm.lastErr = tm.actions.Relay(ctx, row.ID, val)
				}
			case trackerModeBroadcast:
				tm.lastErr = tm.actions.Broadcast(ctx, tm.current.ID, val)
			case trackerModeSpawn:
				tm.lastErr = tm.actions.Spawn(ctx, tm.current.ID, val)
			}
		}
		tm.mode = trackerModeNormal
		tm.input.Blur()
		return tm, tea.Tick(500*time.Millisecond, func(time.Time) tea.Msg { return refreshMsg{} })
	}

	var cmd tea.Cmd
	tm.input, cmd = tm.input.Update(msg)
	return tm, cmd
}

func (tm TrackerModel) manifestViewable() int {
	w, ht := clampDimensions(tm.width, tm.height)
	_, h := contentDimensions(w, ht)
	if h < 1 {
		h = 1
	}
	return h
}

func (tm TrackerModel) updateManifest(msg tea.KeyMsg) (TrackerModel, tea.Cmd) {
	lines := strings.Split(tm.manifestJSON, "\n")
	viewable := tm.manifestViewable()
	maxScroll := len(lines) - viewable
	if maxScroll < 0 {
		maxScroll = 0
	}
	if tm.manifestScrl > maxScroll {
		tm.manifestScrl = maxScroll
	}

	switch msg.String() {
	case "esc", "m", "q":
		tm.mode = trackerModeNormal
		return tm, nil
	case "j", "down":
		if tm.manifestScrl < maxScroll {
			tm.manifestScrl++
		}
	case "k", "up":
		if tm.manifestScrl > 0 {
			tm.manifestScrl--
		}
	}
	return tm, nil
}

// View renders the tracker body (session list or manifest inspect).
func (tm TrackerModel) View() string {
	if tm.mode == trackerModeManifest {
		return tm.viewManifest()
	}
	return tm.viewSessions()
}

func (tm TrackerModel) viewSessions() string {
	outerW, outerH := clampDimensions(tm.width, tm.height)

	compact := outerW > 0 && outerW < compactThreshold
	innerW := outerW - borderlessMargin
	if innerW < 4 {
		innerW = 4
	}

	wantsStatus := tm.lastErr != nil || tm.mode != trackerModeNormal
	_, showStatus := chromeLayout(outerH, wantsStatus)

	title := paneTitleStyle.Render("Party Tracker")
	if tm.current.ID != "" {
		title = paneTitleStyle.Render("Party:") + " " + tm.current.ID
	}

	isInputMode := tm.mode != trackerModeNormal && tm.mode != trackerModeManifest
	footer := tm.trackerFooter(compact, showStatus)
	if isInputMode {
		footer = composerHint
	}

	var body strings.Builder
	detail := tm.currentDetailView(innerW)
	if detail != "" {
		body.WriteString(detail)
	}
	if len(tm.sessions) == 0 {
		if body.Len() > 0 {
			body.WriteString("\n\n")
		}
		body.WriteString(dimTextStyle.Render("No sessions."))
	} else {
		if body.Len() > 0 {
			body.WriteString("\n")
			body.WriteString(lipgloss.NewStyle().Foreground(DividerBorder).Render(strings.Repeat("─", innerW)))
			body.WriteString("\n\n")
		}
		for i, row := range tm.sessions {
			if i > 0 {
				if compact || sameSessionGroup(tm.sessions[i-1], row) {
					body.WriteString("\n")
				} else {
					body.WriteString("\n\n")
				}
			}
			body.WriteString(tm.renderSessionRow(row, i, compact, innerW))
		}
	}

	paneH := outerH
	if isInputMode {
		paneH -= composerHeight
	} else if showStatus {
		paneH--
	}
	if paneH < 3 {
		paneH = 3
	}

	result := borderlessView(title, body.String(), footer, outerW, paneH)
	if isInputMode {
		result += "\n" + tm.renderComposer(outerW)
	} else if showStatus && tm.lastErr != nil {
		result += "\n" + renderStatusBar(outerW, nil, "", tm.lastErr)
	}

	return result
}

func (tm TrackerModel) renderSessionRow(row SessionRow, idx int, compact bool, innerW int) string {
	selected := idx == tm.cursor
	glyph := row.glyph()

	prefix := "  "
	titleStyle := sessionTitleStyle
	if selected {
		prefix = "> "
		titleStyle = selectedSessionTitleStyle
	}

	title := row.displayTitle()
	statusParts := make([]string, 0, 3)
	if row.IsCurrent {
		statusParts = append(statusParts, currentIndicatorStyle.Render("◀"))
	}
	if row.Status != "active" {
		statusParts = append(statusParts, sidebarValueStyle.Render(row.Status))
	} else {
		statusParts = append(statusParts, row.statusDot())
		if compDot := row.companionDot(); compDot != "" {
			statusParts = append(statusParts, compDot)
		}
	}

	basePrefix := prefix + glyph + " "
	suffix := strings.Join(statusParts, "  ")

	maxTitle := innerW - lipgloss.Width(basePrefix)
	if suffix != "" {
		maxTitle -= lipgloss.Width("  " + suffix)
	}
	if maxTitle < 4 {
		maxTitle = 4
	}
	firstLine := basePrefix + titleStyle.Render(truncate(title, maxTitle))
	if suffix != "" {
		firstLine += "  " + suffix
	}
	firstLine = ansi.Truncate(firstLine, innerW, "")

	if compact {
		return firstLine
	}

	metaPrefix := strings.Repeat(" ", lipgloss.Width(prefix)+2)
	if row.SessionType == "worker" || (row.SessionType == "master" && row.WorkerCount > 0) {
		metaPrefix = strings.Repeat(" ", lipgloss.Width(prefix)) + workerGlyphStyle.Render("│") + " "
	}
	metaParts := []string{
		sidebarValueStyle.Render(truncate(row.ID, max(8, innerW/2))),
		noteTextStyle.Render(truncate(shortHomePath(row.Cwd), max(8, innerW/2))),
	}
	secondLine := metaPrefix + strings.Join(metaParts, "  ")
	lines := []string{firstLine, ansi.Truncate(secondLine, innerW, "")}
	if snippet := renderRowSnippet(row, metaPrefix, innerW); snippet != "" {
		lines = append(lines, snippet)
	}
	return strings.Join(lines, "\n")
}

func (tm TrackerModel) currentDetailView(innerW int) string {
	if innerW < 4 {
		return ""
	}

	var lines []string
	if tm.detail.ID == "" {
		lines = append(lines, noteTextStyle.Render("resolving current session..."))
		return strings.Join(lines, "\n")
	}

	lines = append(lines, renderCompanionLine(tm.detail.CompanionName, tm.detail.CompanionStatus, innerW))
	lines = append(lines, renderEvidenceLine(tm.detail.Evidence, innerW))

	return strings.Join(lines, "\n")
}

func (tm TrackerModel) trackerFooter(compact, showStatus bool) string {
	errPrefix := ""
	if tm.lastErr != nil && !showStatus {
		errPrefix = fmt.Sprintf("error: %s · ", tm.lastErr)
	}

	keys := "j/k ⏎ m x/d q"
	if tm.currentIsMaster() {
		keys = "j/k ⏎ r/b s m x/d q"
	}

	if compact {
		return fmt.Sprintf("%s%ds · %s", errPrefix, len(tm.sessions), keys)
	}
	return fmt.Sprintf("%s%d sessions · %s", errPrefix, len(tm.sessions), keys)
}

func (tm TrackerModel) renderComposer(width int) string {
	label := "input"
	switch tm.mode {
	case trackerModeRelay:
		label = "relay"
	case trackerModeBroadcast:
		label = "broadcast"
	case trackerModeSpawn:
		label = "spawn"
	}

	input := tm.input
	input.Width = composerInputWidth(width, label)
	return renderComposerInput(label, input.View(), width)
}

func (tm TrackerModel) viewManifest() string {
	outerW, outerH := clampDimensions(tm.width, tm.height)

	innerW, _ := contentDimensions(outerW, outerH)
	if innerW < 4 {
		innerW = 4
	}

	lines := strings.Split(tm.manifestJSON, "\n")
	viewable := tm.manifestViewable()
	if tm.manifestScrl >= len(lines) {
		tm.manifestScrl = max(0, len(lines)-1)
	}

	end := tm.manifestScrl + viewable
	if end > len(lines) {
		end = len(lines)
	}

	var body strings.Builder
	for i, line := range lines[tm.manifestScrl:end] {
		if i > 0 {
			body.WriteString("\n")
		}
		body.WriteString(truncate(line, innerW))
	}

	title := paneTitleStyle.Render("Manifest: " + truncate(tm.manifestID, innerW-12))

	scrollInfo := ""
	if len(lines) > viewable {
		scrollInfo = fmt.Sprintf("[%d/%d] · ", tm.manifestScrl+1, len(lines))
	}
	footer := scrollInfo + "j/k scroll · esc back"

	scrollLine := -1
	if len(lines) > viewable && viewable > 0 {
		scrollLine = tm.manifestScrl * (viewable - 1) / (len(lines) - viewable)
	}

	return borderedPaneWithScroll(body.String(), title, footer, outerW, outerH, true, scrollLine)
}

func (tm TrackerModel) indexOfSession(id string) int {
	for i, row := range tm.sessions {
		if row.ID == id {
			return i
		}
	}
	return -1
}

func (tm TrackerModel) selectedSession() (SessionRow, bool) {
	if tm.cursor < 0 || tm.cursor >= len(tm.sessions) {
		return SessionRow{}, false
	}
	return tm.sessions[tm.cursor], true
}

func (tm TrackerModel) currentIsMaster() bool {
	return tm.current.SessionType == "master"
}

func (tm TrackerModel) selectedManagedWorker() (SessionRow, bool) {
	row, ok := tm.selectedSession()
	if !ok || !tm.currentIsMaster() {
		return SessionRow{}, false
	}
	if row.SessionType != "worker" || row.ParentID != tm.current.ID {
		return SessionRow{}, false
	}
	return row, true
}

// manifestToSessionRow converts manifest data plus liveness into a render row.
func manifestToSessionRow(id string, m state.Manifest, alive bool) SessionRow {
	sessionType := sessionTypeForManifest(m)
	status := "stopped"
	if alive {
		status = "active"
	}

	return SessionRow{
		ID:          id,
		Title:       m.Title,
		Cwd:         m.Cwd,
		Status:      status,
		SessionType: sessionType,
		ParentID:    m.ExtraString("parent_session"),
		WorkerCount: len(m.Workers),
	}
}

func shortHomePath(path string) string {
	if path == "" {
		return ""
	}
	home, _ := os.UserHomeDir()
	if home != "" && strings.HasPrefix(path, home) {
		return "~" + path[len(home):]
	}
	return path
}

func sessionTypeForManifest(m state.Manifest) string {
	if m.SessionType == "master" {
		return "master"
	}
	if m.ExtraString("parent_session") != "" {
		return "worker"
	}
	return "standalone"
}

func sameSessionGroup(prev, next SessionRow) bool {
	if next.SessionType != "worker" {
		return false
	}
	if next.ParentID == "" {
		return false
	}
	if prev.ID == next.ParentID {
		return true
	}
	return prev.SessionType == "worker" && prev.ParentID == next.ParentID
}

// statusDot returns a single colored dot reflecting the session's overall activity state.
func (s SessionRow) statusDot() string {
	if s.Status != "active" {
		return primaryStateDimStyle.Render("●")
	}
	label := s.liveStatusLabel()
	switch label {
	case "error", "changes":
		return errorTextStyle.Render("●")
	case "waiting":
		return primaryStateWaitingStyle.Render("●")
	case "idle", "done":
		return primaryStateDimStyle.Render("●")
	default: // "working", "ready", "approved", etc.
		return primaryStateActiveStyle.Render("●")
	}
}

// companionDot returns a colored dot for the companion agent's state.
// Returns empty string if the session has no companion.
func (s SessionRow) companionDot() string {
	if !s.HasCompanion {
		return ""
	}
	switch s.CompanionState {
	case string(CompanionWorking):
		return primaryStateActiveStyle.Render("●")
	case "waiting":
		return primaryStateWaitingStyle.Render("●")
	case string(CompanionIdle), "done":
		return primaryStateDimStyle.Render("●")
	case string(CompanionError):
		return errorTextStyle.Render("●")
	default:
		return primaryStateDimStyle.Render("●")
	}
}

func renderRowSnippet(row SessionRow, prefix string, width int) string {
	if row.SessionType == "master" || row.Snippet == "" {
		return ""
	}

	snippet := lastSnippetLine(row.Snippet)
	if snippet == "" {
		return ""
	}

	available := width - lipgloss.Width(prefix)
	if available < 8 {
		available = 8
	}
	return prefix + dimTextStyle.Render(truncate(snippet, available))
}

func lastSnippetLine(snippet string) string {
	lines := strings.Split(strings.TrimSpace(snippet), "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		line := strings.TrimSpace(lines[i])
		if line != "" {
			return line
		}
	}
	return ""
}

func (s SessionRow) displayTitle() string {
	if s.Title != "" {
		return s.Title
	}
	return s.ID
}

func (s SessionRow) glyph() string {
	if s.Status != "active" {
		return stoppedGlyphStyle.Render("○")
	}

	switch s.SessionType {
	case "master":
		return masterGlyphStyle.Render("●")
	case "worker":
		return workerGlyphStyle.Render("│")
	default:
		return standaloneGlyphStyle.Render("●")
	}
}

func (s SessionRow) primaryStateDot() string {
	return renderPrimaryStateDot(s.PrimaryState)
}

func renderPrimaryStateDot(state string) string {
	switch state {
	case "active":
		return primaryStateActiveStyle.Render(PrimaryStateDotActive)
	case "waiting":
		return primaryStateWaitingStyle.Render(PrimaryStateDotWaiting)
	case "idle":
		return primaryStateDimStyle.Render(PrimaryStateDotIdle)
	case "done":
		return primaryStateDimStyle.Render(PrimaryStateDotDone)
	default:
		return ""
	}
}

func verdictStatusLabel(verdict string) string {
	switch verdict {
	case "REQUEST_CHANGES", "FAIL":
		return "changes"
	case "APPROVE", "APPROVED", "PASS":
		return "approved"
	default:
		return ""
	}
}

func stageStatusLabel(stage string) string {
	switch stage {
	case StageError:
		return "error"
	case StagePRReady, StageCriticsOK, StageCodexOK, StageQuick:
		return "ready"
	case StageTesting, StageChecks, StageCritics, StageCodex:
		return "working"
	default:
		return ""
	}
}

func (s SessionRow) liveStatusLabel() string {
	if s.Status != "active" {
		return s.Status
	}
	if s.CompanionState == string(CompanionError) {
		return "error"
	}
	if verdict := verdictStatusLabel(s.CompanionVerdict); verdict == "changes" {
		return verdict
	}
	switch s.CompanionState {
	case string(CompanionWorking):
		return "working"
	case "waiting":
		return "waiting"
	}
	if verdict := verdictStatusLabel(s.CompanionVerdict); verdict != "" {
		return verdict
	}
	switch s.CompanionState {
	case string(CompanionIdle):
		return "idle"
	case "done":
		return "done"
	}
	if label := stageStatusLabel(s.Stage); label != "" {
		return label
	}
	switch s.PrimaryState {
	case "active":
		return "working"
	case "waiting":
		return "waiting"
	case "idle":
		return "idle"
	case "done":
		return "done"
	default:
		return "ready"
	}
}
