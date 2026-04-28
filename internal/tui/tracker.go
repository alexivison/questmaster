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

	"github.com/anthropics/ai-party/tools/party-cli/internal/sessionactivity"
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

// ActivityWindow keeps the tracker activity dot lit briefly after the latest
// observed primary-pane snippet change.
const ActivityWindow = sessionactivity.Window

// SessionRow is the display-ready session data for the tracker.
//
// PrimaryActive is derived from primary snippet changes across refreshes. A
// new change keeps the activity dot lit for ActivityWindow. Companion output
// is not captured for dot purposes.
type SessionRow struct {
	ID            string
	Title         string
	Cwd           string
	PrimaryAgent  string
	Status        string // "active" or "stopped"
	SessionType   string // "master", "worker", or "standalone"
	ParentID      string
	WorkerCount   int
	HasCompanion  bool
	Snippet       string
	PrimaryActive bool
	IsCurrent     bool

	// TodoOverlay is the pre-formatted Claude TodoWrite summary rendered
	// below the snippet line. Empty for Codex rows and rows without a live
	// todo file. See internal/claudetodos.Overlay.FormatLine.
	TodoOverlay string
}

// TrackerSnapshot is the full rendered data set for one refresh tick.
type TrackerSnapshot struct {
	Sessions   []SessionRow
	Current    CurrentSessionDetail
	ObservedAt time.Time
}

// CurrentSessionDetail carries the current session metadata needed by the
// tracker header.
type CurrentSessionDetail struct {
	Title       string
	SessionType string
}

// SessionFetcher loads all session data for the tracker.
type SessionFetcher func(current SessionInfo) (TrackerSnapshot, error)

// snapshotMsg carries an asynchronously fetched tracker snapshot back to Update.
type snapshotMsg struct {
	seq      int
	snapshot TrackerSnapshot
	err      error
}

// TrackerModel is the Bubble Tea sub-model for the unified tracker view.
type TrackerModel struct {
	current       SessionInfo
	sessions      []SessionRow
	detail        CurrentSessionDetail
	cursor        int
	mode          trackerMode
	input         textinput.Model
	width         int
	height        int
	lastErr       error
	blinkOn       bool
	refreshing    bool
	refreshQueued bool
	refreshSeq    int
	activityState sessionactivity.State

	manifestJSON string
	manifestID   string
	manifestScrl int

	relayTargetID string

	fetcher SessionFetcher
	actions TrackerActions

	inputFrameCache trackerInputFrameCache
	testHooks       trackerViewTestHooks
}

type trackerInputFrameCache struct {
	pane  string
	valid bool
}

type trackerViewTestHooks struct {
	renderSessionRow func()
}

// NewTrackerModel creates a tracker with injected dependencies.
func NewTrackerModel(current SessionInfo, fetcher SessionFetcher, actions TrackerActions) TrackerModel {
	ti := textinput.New()
	ti.CharLimit = 500
	ti.Width = 60
	ti.Prompt = ""

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
	tm.invalidateInputFrameCache()
}

func (tm *TrackerModel) requestRefresh() tea.Cmd {
	if tm.fetcher == nil {
		return nil
	}
	if tm.refreshing {
		tm.refreshQueued = true
		return nil
	}

	tm.refreshing = true
	tm.refreshSeq++

	seq := tm.refreshSeq
	current := tm.current
	fetcher := tm.fetcher

	return func() tea.Msg {
		snapshot, err := fetcher(current)
		return snapshotMsg{seq: seq, snapshot: snapshot, err: err}
	}
}

func (tm *TrackerModel) applySnapshot(snapshot TrackerSnapshot) {
	selectedID := tm.selectedSessionID()
	observedAt := snapshot.ObservedAt
	if observedAt.IsZero() {
		observedAt = time.Now()
	}
	tm.updateSnippetActivity(snapshot.Sessions, observedAt)

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

	tm.invalidateInputFrameCache()
}

func (tm *TrackerModel) updateSnippetActivity(rows []SessionRow, now time.Time) {
	observations := make([]sessionactivity.Observation, 0, len(rows))
	keys := make([]string, len(rows))
	for i := range rows {
		key := sessionactivity.PrimaryKey(rows[i].ID)
		keys[i] = key
		observations = append(observations, sessionactivity.Observation{
			Key:     key,
			Snippet: rows[i].Snippet,
			Enabled: rows[i].Status == "active",
		})
	}

	nextState, results := sessionactivity.Evaluate(now, observations, tm.activityState)
	tm.activityState = nextState

	for i := range rows {
		rows[i].PrimaryActive = results[keys[i]].Active
	}
}

func (tm *TrackerModel) finishRefresh(msg snapshotMsg) tea.Cmd {
	if msg.seq != tm.refreshSeq {
		return nil
	}

	tm.refreshing = false
	if msg.err != nil {
		tm.lastErr = msg.err
	} else {
		tm.applySnapshot(msg.snapshot)
	}

	if tm.refreshQueued {
		tm.refreshQueued = false
		return tm.requestRefresh()
	}
	return nil
}

// Update handles key messages for the tracker sub-model.
func (tm TrackerModel) Update(msg tea.Msg) (TrackerModel, tea.Cmd) {
	keyMsg, ok := msg.(tea.KeyMsg)
	if !ok {
		return tm, nil
	}

	if tm.mode == trackerModeManifest {
		next, cmd := tm.updateManifest(keyMsg)
		return next.syncInputFrameCache(), cmd
	}
	if tm.mode != trackerModeNormal {
		next, cmd := tm.updateInput(keyMsg)
		return next.syncInputFrameCache(), cmd
	}
	next, cmd := tm.updateNormal(keyMsg)
	return next.syncInputFrameCache(), cmd
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
			return tm, delayedRefreshCmd()
		}

	case "r":
		if row, ok := tm.selectedRelayTarget(); ok {
			tm.mode = trackerModeRelay
			tm.relayTargetID = row.ID
			tm.input.Placeholder = fmt.Sprintf("message to %s...", row.ID)
			tm.input.Reset()
			tm.input.Focus()
			return tm, textinput.Blink
		}
		tm.lastErr = fmt.Errorf("select another active session to relay")

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

	case "d":
		if row, ok := tm.selectedSession(); ok && tm.actions != nil {
			tm.lastErr = tm.actions.Delete(ctx, row.ParentID, row.ID)
			return tm, delayedRefreshCmd()
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
		tm.relayTargetID = ""
		tm.input.Blur()
		return tm, nil

	case "enter":
		ctx := context.Background()
		val := tm.input.Value()
		if val != "" && tm.actions != nil {
			switch tm.mode {
			case trackerModeRelay:
				if tm.relayTargetID != "" {
					tm.lastErr = tm.actions.Relay(ctx, tm.relayTargetID, val)
				}
			case trackerModeBroadcast:
				tm.lastErr = tm.actions.Broadcast(ctx, tm.current.ID, val)
			case trackerModeSpawn:
				tm.lastErr = tm.actions.Spawn(ctx, tm.current.ID, val)
			}
		}
		tm.mode = trackerModeNormal
		tm.relayTargetID = ""
		tm.input.Blur()
		return tm, delayedRefreshCmd()
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
	isInputMode := tm.mode != trackerModeNormal && tm.mode != trackerModeManifest
	result := ""
	if isInputMode && tm.inputFrameCache.valid {
		result = tm.inputFrameCache.pane
	} else {
		result = tm.renderSessionPane(outerW, outerH, isInputMode)
	}
	if isInputMode {
		result += "\n" + tm.renderComposer(outerW)
	} else if _, showStatus := chromeLayout(outerH, tm.lastErr != nil || tm.mode != trackerModeNormal); showStatus && tm.lastErr != nil {
		result += "\n" + renderStatusBar(outerW, nil, "", tm.lastErr)
	}

	return result
}

func (tm TrackerModel) renderSessionPane(outerW, outerH int, isInputMode bool) string {
	innerW := outerW - borderlessMargin
	if innerW < 4 {
		innerW = 4
	}

	title := tm.trackerPaneTitle()
	showStatus := tm.lastErr != nil && !isInputMode
	footer := ""
	if isInputMode {
		footer = composerHint
	}

	var body strings.Builder
	if len(tm.sessions) == 0 {
		body.WriteString(dimTextStyle.Render("No sessions."))
	} else {
		body.WriteString(tm.renderSessionsArea(innerW, outerH, isInputMode, showStatus, footer != ""))
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

	return borderlessView(title, body.String(), footer, innerW, paneH)
}

// renderSessionsArea renders the session list and scrolls it so the cursor's
// session stays visible when the list is taller than the pane.
func (tm TrackerModel) renderSessionsArea(innerW, outerH int, isInputMode, showStatus, hasFooter bool) string {
	// Gather each session's rendered lines, tracking where each session
	// starts so we can compute the scroll offset in line units.
	var allLines []string
	sessionStart := make([]int, len(tm.sessions))
	sessionEnd := make([]int, len(tm.sessions))
	for i, row := range tm.sessions {
		if i > 0 {
			allLines = append(allLines, "")
		}
		sessionStart[i] = len(allLines)
		rowStr := tm.renderSessionRow(row, i, innerW)
		for _, line := range strings.Split(rowStr, "\n") {
			allLines = append(allLines, line)
		}
		sessionEnd[i] = len(allLines) - 1
	}

	// Lines available for the sessions area = pane minus chrome (title +
	// divider + optional footer + status + composer).
	avail := outerH - 2 // title + divider
	if hasFooter {
		avail--
	}
	if isInputMode {
		avail -= composerHeight
	} else if showStatus {
		avail--
	}
	if avail < 3 {
		avail = 3
	}
	if len(allLines) <= avail {
		return strings.Join(allLines, "\n")
	}

	// Scroll so the cursor's last line is within [scroll, scroll+avail).
	cursorLast := len(allLines) - 1
	if tm.cursor >= 0 && tm.cursor < len(sessionEnd) {
		cursorLast = sessionEnd[tm.cursor]
	}
	scroll := 0
	if cursorLast >= avail {
		scroll = cursorLast - avail + 1
	}
	// But also show the cursor's start if possible (prefer starting at its top).
	if tm.cursor < len(sessionStart) && scroll > sessionStart[tm.cursor] {
		scroll = sessionStart[tm.cursor]
	}
	end := scroll + avail
	if end > len(allLines) {
		end = len(allLines)
	}
	return strings.Join(allLines[scroll:end], "\n")
}

// activityDot returns the colored activity glyph shown before a session title.
// For sessions running a recognized agent, this is the agent icon; otherwise
// it falls back to a filled (active) or hollow (stopped) dot. Color follows
// activityDotStyle (stopped=muted, generating=blinks dim, active=identity).
func (s SessionRow) activityDot(blinkOn bool) string {
	return s.activityDotStyle(blinkOn).Render(s.activityGlyph())
}

// activityGlyph returns the unstyled glyph used as the activity indicator —
// the agent icon when recognized, otherwise the ●/○ dot fallback.
func (s SessionRow) activityGlyph() string {
	if icon := sessionTitleIcon(s.PrimaryAgent); icon != "" {
		return icon
	}
	return dotGlyph(s)
}

func (s SessionRow) activityDotStyle(blinkOn bool) lipgloss.Style {
	if s.Status != "active" {
		return stoppedGlyphStyle
	}
	if s.isGenerating() && !blinkOn {
		return dimActivityStyle
	}
	return identityStyle(s.SessionType)
}

// identityStyle returns the color for an active session's dot when it is
// not currently blinking.
func identityStyle(sessionType string) lipgloss.Style {
	switch sessionType {
	case "master":
		return masterGlyphStyle
	case "worker":
		return workerGlyphStyle
	case "standalone":
		return standaloneGlyphStyle
	default:
		return sessionTitleStyle
	}
}

// isGenerating reports whether the primary activity window is still active.
func (s SessionRow) isGenerating() bool {
	return s.Status == "active" && s.PrimaryActive
}

// workerIndent is the horizontal offset applied to worker session boxes so
// they sit beneath the master. The first 3 cells hold the tree trunk
// (`│` / `├──┬` / `└──┬`) that connects siblings back to the master.
const workerIndent = 3

func (tm TrackerModel) renderSessionRow(row SessionRow, idx int, innerW int) string {
	if tm.testHooks.renderSessionRow != nil {
		tm.testHooks.renderSessionRow()
	}

	selected := idx == tm.cursor

	isWorker := row.SessionType == "worker"
	nextSame := idx+1 < len(tm.sessions) && sameSessionGroup(row, tm.sessions[idx+1])

	// Tree connectors for workers: first line gets ├─ or └─; continuation
	// lines get │ or blank. Masters/standalones render flush-left.
	firstPrefixText, contPrefixText := "", ""
	if isWorker {
		if nextSame {
			firstPrefixText = "┣━ "
			contPrefixText = "┃  "
		} else {
			firstPrefixText = "┗━ "
			contPrefixText = "   "
		}
	}

	firstPrefix := renderPrefix(firstPrefixText)
	contPrefix := renderPrefix(contPrefixText)

	title := row.displayTitle()

	titleStyle := sessionTitleStyle
	switch {
	case row.IsCurrent:
		titleStyle = currentSessionTitleStyle
	case selected:
		titleStyle = selectedSessionTitleStyle
	}

	statusSuffix := ""
	if row.Status != "active" {
		statusSuffix = "  " + sidebarValueStyle.Render(row.Status)
	}

	titleLine := firstPrefix + row.activityDot(tm.blinkOn) + " " + titleStyle.Render(title) + statusSuffix
	if selected {
		titleLine = selectedPrefix(firstPrefixText) +
			selectedStyledText(row.activityDotStyle(tm.blinkOn), row.activityGlyph()) +
			selectedRowStyle.Render(" ") +
			selectedStyledText(titleStyle, title)
		if row.Status != "active" {
			titleLine += selectedRowStyle.Render("  ") + selectedStyledText(sidebarValueStyle, row.Status)
		}
	}

	lines := []string{titleLine}

	if s := lastSnippetLine(row.Snippet); s != "" {
		snippetMax := innerW - lipgloss.Width(contPrefix) - 2 // bar + space
		if snippetMax > 1 {
			s = truncate(s, snippetMax)
		}
		snippetLine := contPrefix + snippetBarStyle.Render("|") + " " + snippetTextStyle.Render(s)
		if selected {
			snippetLine = selectedPrefix(contPrefixText) +
				selectedStyledText(snippetBarStyle, "|") +
				selectedRowStyle.Render(" ") +
				selectedStyledText(snippetTextStyle, s)
		}
		lines = append(lines, snippetLine)
	}

	if s := row.TodoOverlay; s != "" {
		body := "▸ " + s
		maxW := innerW - lipgloss.Width(contPrefix) - 2 // bar + space
		if maxW > 1 {
			body = truncate(body, maxW)
		}
		overlayLine := contPrefix + snippetBarStyle.Render("|") + " " + todoOverlayStyle.Render(body)
		if selected {
			overlayLine = selectedPrefix(contPrefixText) +
				selectedStyledText(snippetBarStyle, "|") +
				selectedRowStyle.Render(" ") +
				selectedStyledText(todoOverlayStyle, body)
		}
		lines = append(lines, overlayLine)
	}

	// Meta: ⚔ id and folder/path, left-aligned with a 2-space gap.
	available := innerW - lipgloss.Width(contPrefix)
	idText := "⚔ " + row.ID
	metaPath := ""
	metaContent := metaTextStyle.Render(idText)
	if p := shortHomePath(row.Cwd); p != "" {
		pathIcon := "\uf114 "
		remaining := available - lipgloss.Width(idText) - 2
		if remaining > lipgloss.Width(pathIcon) {
			pathBody := p
			metaPath = pathIcon + pathBody
			if lipgloss.Width(metaPath) > remaining {
				pathBody = truncate(pathBody, remaining-lipgloss.Width(pathIcon))
				metaPath = pathIcon + pathBody
			}
			metaContent = metaTextStyle.Render(idText) + "  " + metaTextStyle.Render(metaPath)
		}
	}
	metaLine := contPrefix + metaContent
	if selected {
		metaLine = selectedPrefix(contPrefixText) + selectedStyledText(metaTextStyle, idText)
		if metaPath != "" {
			metaLine += selectedRowStyle.Render("  ") + selectedStyledText(metaTextStyle, metaPath)
		}
	}
	lines = append(lines, metaLine)

	if selected {
		for i, line := range lines {
			lines[i] = applySelectedBg(line, innerW)
		}
	}

	return strings.Join(lines, "\n")
}

func padRight(s string, w int) string {
	cur := lipgloss.Width(s)
	if cur >= w {
		return ansi.Truncate(s, w, "")
	}
	return s + strings.Repeat(" ", w-cur)
}

func (tm TrackerModel) renderComposer(width int) string {
	return renderComposerInput(tm.composerLabel(), tm.input.View(), width)
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

func (tm TrackerModel) selectedSessionID() string {
	row, ok := tm.selectedSession()
	if !ok {
		return ""
	}
	return row.ID
}

func (tm TrackerModel) currentIsMaster() bool {
	return tm.currentSessionType() == "master"
}

// selectedRelayTarget returns the selected row if it is a valid relay target:
// active and not the current session.
func (tm TrackerModel) selectedRelayTarget() (SessionRow, bool) {
	row, ok := tm.selectedSession()
	if !ok {
		return SessionRow{}, false
	}
	if row.Status != "active" || row.ID == tm.current.ID {
		return SessionRow{}, false
	}
	return row, true
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

// lastSnippetLine returns the last non-empty agent-output line, skipping
// user-prompt lines (❯). Per-agent output markers (⏺ for Claude, • for Codex,
// ⎿ for tool results) are stripped so all agents render in a uniform format —
// the ▎ quote bar already visually identifies the snippet.
func lastSnippetLine(snippet string) string {
	lines := strings.Split(strings.TrimSpace(snippet), "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		line := strings.TrimSpace(lines[i])
		if line == "" || strings.HasPrefix(line, "❯") {
			continue
		}
		return stripAgentMarker(line)
	}
	return ""
}

// applySelectedBg pads a selected tracker line so the tint reaches the pane's
// full content width even when the rendered segments are shorter.
func applySelectedBg(line string, width int) string {
	cur := lipgloss.Width(line)
	if cur >= width {
		return ansi.Truncate(line, width, "")
	}
	return line + selectedRowStyle.Width(width-cur).Render("")
}

func selectedStyledText(style lipgloss.Style, text string) string {
	return selectedRowStyle.Inherit(style).Render(text)
}

func renderPrefix(prefix string) string {
	if prefix == "" {
		return ""
	}
	if strings.TrimSpace(prefix) == "" {
		return prefix
	}
	return treeGutterStyle.Render(prefix)
}

func selectedPrefix(prefix string) string {
	if prefix == "" {
		return ""
	}
	if strings.TrimSpace(prefix) == "" {
		return selectedRowStyle.Render(prefix)
	}
	return selectedStyledText(treeGutterStyle, prefix)
}

func dotGlyph(s SessionRow) string {
	if s.Status != "active" {
		return "○"
	}
	return "●"
}

// stripAgentMarker removes the leading agent/tool output marker from a line.
// Covers Claude's 6-frame thinking-spinner cycle (· ✻ ✽ ✶ ✳ ✢), Codex's
// bullet, Claude's ⏺ output and ⎿ tool-result prefixes. Returns the line
// unchanged if no known marker is present.
func stripAgentMarker(line string) string {
	for _, marker := range []string{"⏺", "•", "⎿", "·", "✻", "✽", "✶", "✳", "✢"} {
		if strings.HasPrefix(line, marker) {
			return strings.TrimSpace(strings.TrimPrefix(line, marker))
		}
	}
	return line
}

func (s SessionRow) displayTitle() string {
	if s.Title != "" {
		return s.Title
	}
	return s.ID
}

func (tm TrackerModel) currentSessionType() string {
	if tm.current.SessionType != "" {
		return tm.current.SessionType
	}
	if tm.detail.SessionType != "" {
		return tm.detail.SessionType
	}
	if tm.current.Manifest.PartyID != "" {
		return sessionTypeForManifest(tm.current.Manifest)
	}
	return ""
}

func (tm TrackerModel) isComposerMode() bool {
	switch tm.mode {
	case trackerModeRelay, trackerModeBroadcast, trackerModeSpawn:
		return true
	default:
		return false
	}
}

func (tm TrackerModel) composerLabel() string {
	switch tm.mode {
	case trackerModeRelay:
		return "relay"
	case trackerModeBroadcast:
		return "broadcast"
	case trackerModeSpawn:
		return "spawn"
	default:
		return "input"
	}
}

func (tm *TrackerModel) invalidateInputFrameCache() {
	tm.inputFrameCache = trackerInputFrameCache{}
}

func (tm *TrackerModel) syncComposerWidth() {
	outerW, _ := clampDimensions(tm.width, tm.height)
	w := composerInputWidth(outerW, tm.composerLabel()) - 1
	if w < 1 {
		w = 1
	}
	tm.input.Width = w
}

func (tm TrackerModel) syncInputFrameCache() TrackerModel {
	if !tm.isComposerMode() {
		tm.invalidateInputFrameCache()
		return tm
	}

	tm.syncComposerWidth()
	if tm.inputFrameCache.valid {
		return tm
	}

	outerW, outerH := clampDimensions(tm.width, tm.height)
	tm.inputFrameCache = trackerInputFrameCache{
		pane:  tm.renderSessionPane(outerW, outerH, true),
		valid: true,
	}
	return tm
}

func (tm TrackerModel) trackerPaneTitle() string {
	style := paneTitleStyle
	if sessionType := tm.currentSessionType(); sessionType != "" {
		style = style.Foreground(identityStyle(sessionType).GetForeground())
	}
	if title := tm.currentTitle(); title != "" {
		text := title
		if tm.current.ID != "" {
			text = title + " (" + tm.current.ID + ")"
		}
		return style.Render(text)
	}
	if tm.current.ID != "" {
		return style.Render(tm.current.ID)
	}
	return paneTitleStyle.Render("Party Tracker")
}

func (tm TrackerModel) currentTitle() string {
	switch {
	case tm.detail.Title != "":
		return tm.detail.Title
	case tm.current.Title != "":
		return tm.current.Title
	case tm.current.Manifest.Title != "":
		return tm.current.Manifest.Title
	default:
		return ""
	}
}

func sessionTitleIcon(agentName string) string {
	switch agentName {
	case "codex":
		return "\uf44f"
	case "claude":
		return "\U000f06c4"
	default:
		return ""
	}
}

func delayedRefreshCmd() tea.Cmd {
	return tea.Tick(500*time.Millisecond, func(time.Time) tea.Msg { return refreshMsg{} })
}
