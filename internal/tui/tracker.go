package tui

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"

	"github.com/alexivison/questmaster/internal/message"
	"github.com/alexivison/questmaster/internal/quests/quest"
	"github.com/alexivison/questmaster/internal/sessionactivity"
	"github.com/alexivison/questmaster/internal/state"
)

// doneToIdleGrace is how long a "done" pane stays green before the tracker
// auto-flips it to idle. The tracker refresh tick runs ~1s, so without a
// grace window the user (and any other tracker pane) almost never sees the
// post-Stop green glyph.
const doneToIdleGrace = 10 * time.Second

// spinnerFrames is the rotating glyph cycle used as the "working" status
// glyph. Arrow rotation — letter-height across all monospace fonts, unlike
// braille / block elements which fill the cell vertically.
var spinnerFrames = []string{"←", "↖", "↑", "↗", "→", "↘", "↓", "↙"}

// trackerMode is the input mode for the unified tracker.
type trackerMode int

const (
	trackerModeNormal trackerMode = iota
	trackerModeRelay
	trackerModeBroadcast
	trackerModeSpawn
	trackerModeManifest
	trackerModeColor
)

// SessionRow is the display-ready session data for the tracker.
//
// State / LastKind come from the per-session state.json that hooks write.
type SessionRow struct {
	ID           string
	Title        string
	Cwd          string
	PrimaryAgent string
	Status       string // "active" or "stopped"
	SessionType  string // "master", "worker", or "standalone"
	ParentID     string
	WorkerCount  int
	DisplayColor string
	Snippet      string
	State        string // working|blocked|done|idle|starting|stopped|unknown
	LastKind     string // last hook event kind (drives streaming-prose suffix)
	WorkingSince time.Time
	IsCurrent    bool

	// QuestID/QuestTitle carry the session's attached quest (master/standalone
	// only; workers inherit via the tree and show no line). Derived from the
	// session scan, never stored on the quest.
	QuestID    string
	QuestTitle string
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
	refreshing    bool
	refreshQueued bool
	refreshSeq    int

	hasWorking      bool
	spinnerFrame    int
	sessionsVersion int

	manifestJSON string
	manifestID   string
	manifestScrl int

	relayTargetID string

	colorTargetID string
	colorOptions  []string
	colorIndex    int

	fetcher SessionFetcher
	actions TrackerActions

	inputFrameCache  trackerInputFrameCache
	normalFrameCache trackerNormalFrameCache
	testHooks        trackerViewTestHooks
}

type trackerInputFrameCache struct {
	pane  string
	valid bool
}

type trackerNormalFrameCache struct {
	frame string
	key   trackerNormalFrameCacheKey
	valid bool
}

type trackerNormalFrameCacheKey struct {
	sessionsVersion int
	cursor          int
	spinnerFrame    int
	width           int
	height          int
	lastErr         string
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
	oldID := tm.current.ID
	oldTitle := tm.currentTitle()
	oldType := tm.currentSessionType()

	tm.current = current
	if tm.current.ID != oldID || tm.currentTitle() != oldTitle || tm.currentSessionType() != oldType {
		tm.invalidateFrameCaches()
	}
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

func (tm *TrackerModel) applySnapshot(snapshot TrackerSnapshot) bool {
	selectedID := tm.selectedSessionID()
	wasWorking := tm.hasWorking
	// state.json Activity (via updateSnippetActivity) is authoritative;
	// preserveLastSnippets only acts as a fallback for rows where Evaluate
	// returned no Activity (e.g. sessions without hooks installed).
	tm.updateSnippetActivity(snapshot.Sessions)
	tm.preserveLastSnippets(snapshot.Sessions)

	tm.sessions = snapshot.Sessions
	tm.detail = snapshot.Current
	tm.lastErr = nil
	tm.hasWorking = hasWorkingSession(tm.sessions)
	tm.sessionsVersion++

	if tm.current.ID != "" {
		go markSessionObserved(tm.current.ID)
	}

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

	tm.invalidateFrameCaches()
	return tm.hasWorking && !wasWorking
}

func hasWorkingSession(rows []SessionRow) bool {
	for _, row := range rows {
		if row.State == "working" {
			return true
		}
	}
	return false
}

func (tm *TrackerModel) preserveLastSnippets(rows []SessionRow) {
	if len(tm.sessions) == 0 {
		return
	}

	previous := make(map[string]string, len(tm.sessions))
	for _, row := range tm.sessions {
		if strings.TrimSpace(row.Snippet) != "" {
			previous[row.ID] = row.Snippet
		}
	}
	for i := range rows {
		if strings.TrimSpace(rows[i].Snippet) == "" {
			rows[i].Snippet = previous[rows[i].ID]
		}
	}
}

func (tm *TrackerModel) updateSnippetActivity(rows []SessionRow) {
	observations := make([]sessionactivity.Observation, 0, len(rows))
	keys := make([]string, len(rows))
	for i := range rows {
		key := sessionactivity.PrimaryKey(rows[i].ID)
		keys[i] = key
		observations = append(observations, sessionactivity.Observation{
			Key:       key,
			SessionID: rows[i].ID,
			Enabled:   rows[i].Status == "active",
		})
	}

	results := sessionactivity.Evaluate(observations)

	for i := range rows {
		result := results[keys[i]]
		// Production rows arrive from the fetcher with State="" so the
		// Evaluate result is authoritative. Tests and other callers that
		// pre-populate State (e.g. a snippet renderer test that wants to
		// pin the dot to "working") get to keep their value.
		if rows[i].State == "" {
			rows[i].State = result.State
		}
		if rows[i].LastKind == "" {
			rows[i].LastKind = result.LastKind
		}
		// WorkingSince mirrors the row's authoritative state. Always copy
		// it (including the zero value) so a working→idle transition
		// clears any stale value carried over from a prior render.
		rows[i].WorkingSince = result.WorkingSince
		// Snippet, unlike State/LastKind, must always reflect the latest
		// state.json Activity — otherwise a stale snippet carried over by
		// preserveLastSnippets would never be replaced.
		if result.Activity != "" {
			rows[i].Snippet = result.Activity
		}
	}
}

// markSessionObserved bumps SeenAt on the current session's state.json
// and flips done → idle when the tracker has observed the session after
// the most recent hook event. Both transitions run inside the per-session
// flock via state.UpdateSessionState, so concurrent hook writes cannot be
// clobbered. Sessions that have no state.json yet (hookless agents) are
// left alone — we never create state files from the tracker side.
func markSessionObserved(id string) {
	if !state.IsValidSessionID(id) {
		return
	}
	existing, err := state.LoadSessionState(id)
	if err != nil || existing == nil {
		return
	}
	_ = state.UpdateSessionState(id, func(ss *state.SessionState) bool {
		ss.SeenAt = time.Now().UTC()
		if p, ok := ss.Panes["primary"]; ok && p.State == "done" && ss.SeenAt.Sub(p.LastEvent) >= doneToIdleGrace {
			p.State = "idle"
			ss.Panes["primary"] = p
		}
		return true
	})
}

func (tm *TrackerModel) finishRefresh(msg snapshotMsg) (tea.Cmd, bool) {
	if msg.seq != tm.refreshSeq {
		return nil, false
	}

	tm.refreshing = false
	startSpinner := false
	if msg.err != nil {
		tm.setLastErr(msg.err)
	} else {
		startSpinner = tm.applySnapshot(msg.snapshot)
	}

	if tm.refreshQueued {
		tm.refreshQueued = false
		return tm.requestRefresh(), startSpinner
	}
	return nil, startSpinner
}

// Update handles key messages for the tracker sub-model.
func (tm TrackerModel) Update(msg tea.Msg) (TrackerModel, tea.Cmd) {
	keyMsg, ok := msg.(tea.KeyMsg)
	if !ok {
		return tm, nil
	}

	if tm.mode == trackerModeManifest {
		next, cmd := tm.updateManifest(keyMsg)
		return next.syncFrameCaches(), cmd
	}
	if tm.mode == trackerModeColor {
		next, cmd := tm.updateColor(keyMsg)
		return next.syncFrameCaches(), cmd
	}
	if tm.mode != trackerModeNormal {
		next, cmd := tm.updateInput(keyMsg)
		return next.syncFrameCaches(), cmd
	}
	next, cmd := tm.updateNormal(keyMsg)
	return next.syncFrameCaches(), cmd
}

func (tm TrackerModel) updateNormal(msg tea.KeyMsg) (TrackerModel, tea.Cmd) {
	ctx := context.Background()
	tm.setLastErr(nil)

	switch msg.String() {
	case "q", "ctrl+c":
		return tm, tea.Quit

	case "j", "down":
		if tm.cursor < len(tm.sessions)-1 {
			tm.cursor++
			tm.invalidateNormalFrameCache()
		}

	case "k", "up":
		if tm.cursor > 0 {
			tm.cursor--
			tm.invalidateNormalFrameCache()
		}

	case "enter":
		row, ok := tm.selectedSession()
		if !ok || tm.actions == nil {
			return tm, nil
		}
		switch row.Status {
		case "active":
			go markSessionObserved(row.ID)
			tm.setLastErr(tm.actions.Attach(ctx, tm.current.ID, row.ID))
			return tm, delayedRefreshCmd()
		case "stopped":
			tm.setLastErr(tm.actions.Continue(ctx, row.ID))
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
		tm.setLastErr(fmt.Errorf("select another active session to relay"))

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
			next, shouldAttach := tm.nextActiveAfterDelete(row)
			err := tm.actions.Delete(ctx, row.ParentID, row.ID)
			if err == nil && shouldAttach && row.ID == tm.current.ID {
				err = tm.actions.Attach(ctx, tm.current.ID, next.ID)
			}
			tm.setLastErr(err)
			return tm, delayedRefreshCmd()
		}

	case "m":
		if row, ok := tm.selectedSession(); ok && tm.actions != nil {
			j, err := tm.actions.ManifestJSON(row.ID)
			if err != nil {
				tm.setLastErr(err)
			} else {
				tm.mode = trackerModeManifest
				tm.manifestJSON = j
				tm.manifestID = row.ID
				tm.manifestScrl = 0
			}
		}

	case "c":
		if row, ok := tm.selectedSession(); ok {
			if row.SessionType == "worker" {
				return tm, nil
			}
			tm.mode = trackerModeColor
			tm.colorTargetID = row.ID
			// "" leads the cycle so a session can be reset to inherit/default,
			// matching the picker's color selector. Workers are skipped above:
			// their tracker color is inherited from the parent master.
			tm.colorOptions = append([]string{""}, state.DisplayColorOptions()...)
			tm.colorIndex = colorOptionIndex(tm.colorOptions, row.DisplayColor)
		}
	}

	return tm, nil
}

// updateColor handles the on-the-fly display-color cycler. The selected row's
// gutter previews the candidate live; enter commits, esc/q cancels with no
// write.
func (tm TrackerModel) updateColor(msg tea.KeyMsg) (TrackerModel, tea.Cmd) {
	switch msg.String() {
	case "esc", "q":
		tm.mode = trackerModeNormal
		tm.colorTargetID = ""
		return tm, nil

	case "left", "h":
		tm.colorIndex = wrapIndex(tm.colorIndex-1, len(tm.colorOptions))

	case "right", "l":
		tm.colorIndex = wrapIndex(tm.colorIndex+1, len(tm.colorOptions))

	case "enter":
		if tm.actions != nil && tm.colorTargetID != "" {
			tm.setLastErr(tm.actions.SetDisplayColor(tm.colorTargetID, tm.previewColor()))
		}
		tm.mode = trackerModeNormal
		tm.colorTargetID = ""
		return tm, delayedRefreshCmd()
	}

	return tm, nil
}

// previewColor is the color the cycler currently points at.
func (tm TrackerModel) previewColor() string {
	if tm.colorIndex < 0 || tm.colorIndex >= len(tm.colorOptions) {
		return ""
	}
	return tm.colorOptions[tm.colorIndex]
}

// colorOptionIndex returns the index of color in options, or 0 when absent.
func colorOptionIndex(options []string, color string) int {
	for i, opt := range options {
		if opt == color {
			return i
		}
	}
	return 0
}

// wrapIndex wraps idx into [0,length), treating out-of-range as cyclic.
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
					tm.setLastErr(tm.actions.Relay(ctx, tm.relayTargetID, val))
				}
			case trackerModeBroadcast:
				tm.setLastErr(broadcastFeedback(tm.actions.Broadcast(ctx, tm.current.ID, val)))
			case trackerModeSpawn:
				tm.setLastErr(tm.actions.Spawn(ctx, tm.current.ID, val))
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

// broadcastFeedback turns a broadcast outcome into a status-line error so the
// result is never silently dropped. Full delivery returns nil (silent success,
// matching relay). Transport/send errors, no registered workers, and incomplete
// delivery all surface with delivered/registered counts.
func broadcastFeedback(res message.BroadcastResult, err error) error {
	if err != nil {
		return fmt.Errorf("broadcast: delivered to %d of %d workers: %w", res.Delivered, res.Registered, err)
	}
	if res.Registered == 0 {
		return errors.New("broadcast: no workers registered")
	}
	if res.Delivered < res.Registered {
		return fmt.Errorf("broadcast: delivered to %d of %d workers", res.Delivered, res.Registered)
	}
	return nil
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
	if tm.mode == trackerModeColor {
		// Color mode renders the list like normal mode but with an in-pane
		// hint footer and a live gutter preview; it is never cached so each
		// cycle keystroke repaints.
		return tm.renderSessionPane(outerW, outerH, false)
	}
	isInputMode := tm.mode != trackerModeNormal && tm.mode != trackerModeManifest
	if isInputMode {
		result := ""
		if tm.inputFrameCache.valid {
			result = tm.inputFrameCache.pane
		} else {
			result = tm.renderSessionPane(outerW, outerH, true)
		}
		return result + "\n" + tm.renderComposer(outerW)
	}

	key := tm.normalFrameCacheKey(outerW, outerH)
	if tm.normalFrameCache.valid && tm.normalFrameCache.key == key {
		return tm.normalFrameCache.frame
	}
	return tm.renderNormalFrame(outerW, outerH)
}

func (tm TrackerModel) renderNormalFrame(outerW, outerH int) string {
	result := tm.renderSessionPane(outerW, outerH, false)
	if _, showStatus := chromeLayout(outerH, tm.lastErr != nil); showStatus && tm.lastErr != nil {
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
	switch {
	case isInputMode:
		footer = composerHint
	case tm.mode == trackerModeColor:
		footer = colorHint
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

// activityDot returns the colored activity glyph shown before a session
// title. The glyph is always the agent icon (Claude / Codex / Pi); the
// color is steady — per-agent for active rows, muted for inactive rows.
// State signalling moved to the trailing status-glyph / status-word pair.
func (s SessionRow) activityDot() string {
	return s.activityDotStyle().Render(s.activityGlyph())
}

// activityGlyph returns the unstyled glyph used as the activity indicator.
// Active rows always show the agent icon (or '○' when the agent is unknown);
// inactive rows show '○'. Per-state symbology lives in stateGlyph.
func (s SessionRow) activityGlyph() string {
	if s.Status != "active" {
		return "○"
	}
	if icon := sessionTitleIcon(s.PrimaryAgent); icon != "" {
		return icon
	}
	return "○"
}

// activityDotStyle returns the lipgloss style for the activity glyph. The
// color is agent-based (Claude / Codex / Pi) so the engine driving the row
// is identifiable at a glance. Inactive rows render in the muted stopped
// color. State signalling lives on the trailing status glyph + word.
func (s SessionRow) activityDotStyle() lipgloss.Style {
	if s.Status != "active" {
		return stoppedGlyphStyle
	}
	return agentIdentityStyle(s.PrimaryAgent)
}

// stateGlyph returns the unstyled glyph that sits in front of the status
// word. Working frames cycle through the braille spinner; every other
// state is a single literal glyph. Starting renders as the idle glyph so
// the user sees "idle (started)" with a steady marker instead of a spinner
// while the 5s grace window runs.
func stateGlyph(state string, spinnerFrame int) string {
	switch state {
	case "working":
		idx := spinnerFrame % len(spinnerFrames)
		if idx < 0 {
			idx += len(spinnerFrames)
		}
		return spinnerFrames[idx]
	case "blocked":
		return "▲"
	case "done":
		return "✓"
	case "idle", "starting":
		return "○"
	case "stopped":
		return "■"
	default:
		return "?"
	}
}

// statusSeparator is the literal gap between the truncated title and the
// trailing state glyph + word. A single space keeps the status close to
// the title without crowding it; the state glyph itself already provides
// visual separation. Kept in one place so the width budget and the
// rendered line stay in sync.
const statusSeparator = " "

// statusWord returns the literal state word displayed at the end of a row's
// title line. Starting renders as "idle (started)" so the user sees a
// steady idle marker while the 5s grace window runs; the internal state
// stays "starting" so downstream logic can still transition it. Anything
// unrecognised collapses to "unknown" so the column is never blank.
func (s SessionRow) statusWord() string {
	switch s.State {
	case "starting":
		return "idle (started)"
	case "working", "blocked", "done", "idle", "stopped", "unknown":
		return s.State
	}
	return "unknown"
}

// statusWordStyle returns the lipgloss style shared by the trailing status
// glyph and the status word. Colors are ANSI per-state (working → yellow,
// blocked → red bold, done → green, idle/starting/stopped/unknown → dark
// gray) so a glance at the trailing column communicates the session's
// state independent of agent identity. Inactive rows render in the muted
// stopped color.
func (s SessionRow) statusWordStyle() lipgloss.Style {
	if s.Status != "active" {
		return stoppedGlyphStyle
	}
	switch s.State {
	case "working":
		return workingGlyphStyle
	case "blocked":
		return blockedGlyphStyle
	case "done":
		return doneGlyphStyle
	case "idle", "starting":
		return idleGlyphStyle
	}
	return stoppedGlyphStyle
}

// formatWorkingDuration formats how long a session has been working.
// Sub-second precision is dropped. Under a minute renders seconds only
// ("12s"). Under an hour renders "Xm" or "XmYs" with seconds omitted at
// the minute boundary. At an hour or more renders "XhYm" — no seconds,
// since the user only cares about coarse magnitude past that point.
func formatWorkingDuration(d time.Duration) string {
	d = d.Truncate(time.Second)
	if d < 0 {
		d = 0
	}
	if d < time.Minute {
		return fmt.Sprintf("%ds", int(d.Seconds()))
	}
	if d < time.Hour {
		m := int(d / time.Minute)
		s := int((d % time.Minute) / time.Second)
		if s == 0 {
			return fmt.Sprintf("%dm", m)
		}
		return fmt.Sprintf("%dm%ds", m, s)
	}
	h := int(d / time.Hour)
	m := int((d % time.Hour) / time.Minute)
	return fmt.Sprintf("%dh%dm", h, m)
}

// truncateTitleForStatus fits title into budget cells, appending '…' if it
// had to be cut. budget <= 0 returns "" so the trailing state word stays
// visible at extreme narrow widths (status visibility wins).
func truncateTitleForStatus(title string, budget int) string {
	if budget <= 0 {
		return ""
	}
	if lipgloss.Width(title) <= budget {
		return title
	}
	if budget == 1 {
		return "…"
	}
	return ansi.Truncate(title, budget, "…")
}

const displayColorGutterGlyph = "▌"

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

	// In color mode the cursor row previews the candidate color live.
	displayColor := row.DisplayColor
	if !isWorker && tm.mode == trackerModeColor && idx == tm.cursor {
		displayColor = tm.previewColor()
	}

	firstPrefix := renderPrefix(firstPrefixText, displayColor)
	contPrefix := renderPrefix(contPrefixText, displayColor)
	displayGutter := ""
	selectedGutter := ""
	displayGutterWidth := 0
	if !isWorker {
		displayGutter = renderDisplayColorGutter(displayColor)
		selectedGutter = selectedDisplayColorGutter(displayColor)
		displayGutterWidth = lipgloss.Width(displayColorGutterGlyph) + 1
	}

	title := row.displayTitle()

	titleStyle := titleStyleForRow(row.PrimaryAgent, selected, row.IsCurrent)

	sword := row.statusWord()
	swordStyle := row.statusWordStyle()
	sglyph := stateGlyph(row.State, tm.spinnerFrame)
	durationSuffix := ""
	if row.State == "working" && !row.WorkingSince.IsZero() {
		durationSuffix = " " + formatWorkingDuration(time.Since(row.WorkingSince))
	}
	indentWidth := displayGutterWidth + lipgloss.Width(firstPrefix) + lipgloss.Width(row.activityGlyph()) + 1
	trailingWidth := lipgloss.Width(statusSeparator) + lipgloss.Width(sglyph) + 1 + lipgloss.Width(sword) + lipgloss.Width(durationSuffix)
	displayedTitle := truncateTitleForStatus(title, innerW-indentWidth-trailingWidth)

	titleLine := displayGutter + firstPrefix + row.activityDot() + " " +
		titleStyle.Render(displayedTitle) +
		metaTextStyle.Render(statusSeparator) +
		swordStyle.Render(sglyph) + " " +
		swordStyle.Render(sword) +
		metaTextStyle.Render(durationSuffix)
	if selected {
		titleLine = selectedGutter +
			selectedPrefix(firstPrefixText, displayColor) +
			selectedStyledText(row.activityDotStyle(), row.activityGlyph()) +
			selectedRowStyle.Render(" ") +
			selectedStyledText(titleStyle, displayedTitle) +
			selectedStyledText(metaTextStyle, statusSeparator) +
			selectedStyledText(swordStyle, sglyph) +
			selectedRowStyle.Render(" ") +
			selectedStyledText(swordStyle, sword) +
			selectedStyledText(metaTextStyle, durationSuffix)
	}

	lines := []string{titleLine}

	// Quest line: master/standalone sessions on a quest get a single
	// "⚑ id · goal" line (no status, no worker line). Free sessions and workers
	// show nothing.
	if !isWorker && row.QuestID != "" {
		questMax := innerW - displayGutterWidth - lipgloss.Width(contPrefix)
		if questMax < 1 {
			questMax = 1
		}
		q := quest.Quest{ID: row.QuestID, Title: row.QuestTitle}
		questLine := displayGutter + contPrefix + quest.RenderTrackerLine(&q, questMax)
		if selected {
			// Redraw on the selected tint, keeping per-segment colour: the
			// pre-styled RenderTrackerLine carries ANSI resets that would
			// otherwise leave the quest line uncovered by the background.
			questLine = selectedDisplayColorGutter(displayColor) +
				selectedPrefix(contPrefixText, displayColor) +
				selectedQuestLine(row.QuestID, row.QuestTitle, questMax)
		}
		lines = append(lines, questLine)
	}

	if s := composeSnippetLine(row); s != "" {
		snippetMax := innerW - displayGutterWidth - lipgloss.Width(contPrefix) - 2 // bar + space
		if snippetMax > 1 {
			s = truncate(s, snippetMax)
		}
		snippetLine := displayGutter + contPrefix + snippetBarStyle.Render("|") + " " + snippetTextStyle.Render(s)
		if selected {
			snippetLine = selectedGutter +
				selectedPrefix(contPrefixText, displayColor) +
				selectedStyledText(snippetBarStyle, "|") +
				selectedRowStyle.Render(" ") +
				selectedStyledText(snippetTextStyle, s)
		}
		lines = append(lines, snippetLine)
	}

	// Meta: role glyph + id and folder/path, left-aligned with a 2-space gap.
	available := innerW - displayGutterWidth - lipgloss.Width(contPrefix)
	idText := sessionRoleIcon(row.SessionType) + " " + row.ID
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
	metaLine := displayGutter + contPrefix + metaContent
	if selected {
		metaLine = selectedGutter +
			selectedPrefix(contPrefixText, displayColor) +
			selectedStyledText(metaTextStyle, idText)
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

func (tm TrackerModel) nextActiveAfterDelete(deleted SessionRow) (SessionRow, bool) {
	deletedIDs := map[string]struct{}{deleted.ID: {}}
	if deleted.SessionType == "master" {
		for _, row := range tm.sessions {
			if row.SessionType == "worker" && row.ParentID == deleted.ID {
				deletedIDs[row.ID] = struct{}{}
			}
		}
	}

	isCandidate := func(row SessionRow) bool {
		if row.Status != "active" {
			return false
		}
		_, deleted := deletedIDs[row.ID]
		return !deleted
	}

	idx := tm.indexOfSession(deleted.ID)
	if idx < 0 {
		idx = tm.cursor
	}
	for i := idx + 1; i < len(tm.sessions); i++ {
		if isCandidate(tm.sessions[i]) {
			return tm.sessions[i], true
		}
	}
	for i := idx - 1; i >= 0; i-- {
		if isCandidate(tm.sessions[i]) {
			return tm.sessions[i], true
		}
	}
	for _, row := range tm.sessions {
		if isCandidate(row) {
			return row, true
		}
	}
	return SessionRow{}, false
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
		ID:           id,
		Title:        m.Title,
		Cwd:          m.Cwd,
		Status:       status,
		SessionType:  sessionType,
		ParentID:     m.ExtraString("parent_session"),
		WorkerCount:  len(m.Workers),
		DisplayColor: m.DisplayColor(),
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

// composeSnippetLine returns the rendered snippet line for a session row:
// the streaming snippet text with a trailing "…" while the agent is mid-tool.
// Returns "" when the snippet is empty so the caller can skip emitting an
// empty line.
func composeSnippetLine(row SessionRow) string {
	snippetText := lastSnippetLine(row.Snippet)
	if snippetText != "" && streamingProseSuffix(row.State, row.LastKind) {
		snippetText += " …"
	}
	return snippetText
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

// Quest-line segment colours, matching the quest renderer's theme (amber flag,
// cyan id, faint separator, muted goal). Used to redraw the quest line under
// the selection tint while keeping its per-segment colour (a plain re-render
// would wash it out; lipgloss resets in the pre-styled line would drop the bg).
var (
	questLineFlagStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("#e6b860"))
	questLineIDStyle   = lipgloss.NewStyle().Foreground(lipgloss.Color("#4ec3d6"))
	questLineSepStyle  = lipgloss.NewStyle().Foreground(lipgloss.Color("#3a4354"))
	questLineGoalStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("#7e8a9e"))
)

// selectedQuestLine redraws "⚑ id · goal" on the selection background, keeping
// each segment's colour. It mirrors quest.RenderTrackerLine's format and
// width budgeting.
func selectedQuestLine(id, goal string, width int) string {
	flag, sep := "⚑", "·"
	prefix := flag + " " + id + " " + sep + " "
	budget := width - lipgloss.Width(prefix)
	if budget < 1 {
		return selectedStyledText(questLineFlagStyle, flag) + selectedStyledText(questLineIDStyle, " "+id)
	}
	if lipgloss.Width(goal) > budget {
		goal = ansi.Truncate(goal, budget, "…")
	}
	return selectedStyledText(questLineFlagStyle, flag) +
		selectedRowStyle.Render(" ") +
		selectedStyledText(questLineIDStyle, id) +
		selectedRowStyle.Render(" ") +
		selectedStyledText(questLineSepStyle, sep) +
		selectedRowStyle.Render(" ") +
		selectedStyledText(questLineGoalStyle, goal)
}

func renderDisplayColorGutter(color string) string {
	return displayColorGutterStyle(color).Render(displayColorGutterGlyph) + " "
}

func selectedDisplayColorGutter(color string) string {
	return selectedStyledText(displayColorGutterStyle(color), displayColorGutterGlyph) + selectedRowStyle.Render(" ")
}

func displayColorGutterStyle(color string) lipgloss.Style {
	if strings.TrimSpace(color) == "" {
		return treeGutterStyleFor()
	}
	return lipgloss.NewStyle().Foreground(displayColorForeground(color))
}

func displayColorForeground(color string) lipgloss.Color {
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

func renderPrefix(prefix, color string) string {
	if prefix == "" {
		return ""
	}
	if strings.TrimSpace(prefix) == "" {
		return prefix
	}
	return treePrefixStyle(color).Render(prefix)
}

func selectedPrefix(prefix, color string) string {
	if prefix == "" {
		return ""
	}
	if strings.TrimSpace(prefix) == "" {
		return selectedRowStyle.Render(prefix)
	}
	return selectedStyledText(treePrefixStyle(color), prefix)
}

func treePrefixStyle(color string) lipgloss.Style {
	if strings.TrimSpace(color) == "" {
		return treeGutterStyleFor()
	}
	return lipgloss.NewStyle().Foreground(displayColorForeground(color)).Bold(true)
}

// streamingProseSuffix reports whether the renderer should append " …" to
// the snippet line. Hooks are event-driven, so prose between two tool
// calls is invisible. When the agent is "working" right after a tool
// finished or a user-prompt landed, the trailing ellipsis signals
// "probably writing prose right now" — the only thing we know.
func streamingProseSuffix(state, lastKind string) bool {
	if state != "working" {
		return false
	}
	switch lastKind {
	case "PostToolUse", "UserPromptSubmit":
		return true
	}
	return false
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
	if tm.current.Manifest.SessionID != "" {
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

func (tm *TrackerModel) invalidateNormalFrameCache() {
	tm.normalFrameCache = trackerNormalFrameCache{}
}

func (tm *TrackerModel) invalidateFrameCaches() {
	tm.invalidateInputFrameCache()
	tm.invalidateNormalFrameCache()
}

func (tm *TrackerModel) setLastErr(err error) {
	if sameError(tm.lastErr, err) {
		return
	}
	tm.lastErr = err
	tm.invalidateNormalFrameCache()
}

func sameError(a, b error) bool {
	if a == nil || b == nil {
		return a == b
	}
	return a.Error() == b.Error()
}

func (tm *TrackerModel) syncComposerWidth() {
	outerW, _ := clampDimensions(tm.width, tm.height)
	w := composerInputWidth(outerW, tm.composerLabel()) - 1
	if w < 1 {
		w = 1
	}
	tm.input.Width = w
}

func (tm TrackerModel) syncFrameCaches() TrackerModel {
	if tm.isComposerMode() {
		tm.invalidateNormalFrameCache()
		return tm.syncInputFrameCache()
	}
	if tm.mode == trackerModeNormal {
		tm.invalidateInputFrameCache()
		return tm.syncNormalFrameCache()
	}
	tm.invalidateFrameCaches()
	return tm
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

func (tm TrackerModel) syncNormalFrameCache() TrackerModel {
	if tm.mode != trackerModeNormal {
		tm.invalidateNormalFrameCache()
		return tm
	}

	outerW, outerH := clampDimensions(tm.width, tm.height)
	key := tm.normalFrameCacheKey(outerW, outerH)
	if tm.normalFrameCache.valid && tm.normalFrameCache.key == key {
		return tm
	}

	tm.normalFrameCache = trackerNormalFrameCache{
		frame: tm.renderNormalFrame(outerW, outerH),
		key:   key,
		valid: true,
	}
	return tm
}

func (tm TrackerModel) normalFrameCacheKey(outerW, outerH int) trackerNormalFrameCacheKey {
	spinnerFrame := 0
	if tm.hasWorking {
		spinnerFrame = tm.spinnerFrame
	}
	key := trackerNormalFrameCacheKey{
		sessionsVersion: tm.sessionsVersion,
		cursor:          tm.cursor,
		spinnerFrame:    spinnerFrame,
		width:           outerW,
		height:          outerH,
	}
	if tm.lastErr != nil {
		key.lastErr = tm.lastErr.Error()
	}
	return key
}

func (tm TrackerModel) trackerPaneTitle() string {
	glyph := sessionRoleIcon(tm.currentSessionType()) + " "
	if title := tm.currentTitle(); title != "" {
		text := title
		if tm.current.ID != "" {
			text = title + " (" + tm.current.ID + ")"
		}
		return trackerTitleStyle.Render(glyph + text)
	}
	if tm.current.ID != "" {
		return trackerTitleStyle.Render(glyph + tm.current.ID)
	}
	return trackerTitleStyle.Render(glyph + "Party Tracker")
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

// sessionRoleIcon returns the meta-row glyph for a session's role.
// Adventuring-party iconography: masters get crossed swords, workers get
// a hammer-and-pick, standalone sessions get a Maltese cross. Unknown or
// empty roles fall back to the master glyph so masters with a missing
// SessionType stay visible.
func sessionRoleIcon(sessionType string) string {
	switch sessionType {
	case "master":
		return "⚔"
	case "worker":
		return "⚒"
	case "standalone":
		return "✠"
	default:
		return "⚔"
	}
}

func sessionTitleIcon(agentName string) string {
	switch agentName {
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

func delayedRefreshCmd() tea.Cmd {
	return tea.Tick(500*time.Millisecond, func(time.Time) tea.Msg { return refreshMsg{} })
}
