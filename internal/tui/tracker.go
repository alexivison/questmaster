package tui

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
)

// trackerMode is the input mode for the master tracker.
type trackerMode int

const (
	trackerModeNormal trackerMode = iota
	trackerModeRelay
	trackerModeBroadcast
	trackerModeSpawn
	trackerModeManifest
)

// WorkerRow is the display-ready worker data for the tracker.
type WorkerRow struct {
	ID      string
	Title   string
	Status  string // "active" or "stopped"
	Snippet string
}

// WorkerFetcher loads worker data for the tracker.
type WorkerFetcher func(masterID string) []WorkerRow

// TrackerModel is the Bubble Tea sub-model for the master tracker view.
type TrackerModel struct {
	masterID string
	workers  []WorkerRow
	cursor   int
	mode     trackerMode
	input    textinput.Model
	width    int
	height   int
	lastErr  error

	manifestJSON string
	manifestID   string
	manifestScrl int

	fetcher WorkerFetcher
	actions TrackerActions
}

// NewTrackerModel creates a tracker with injected dependencies.
func NewTrackerModel(masterID string, fetcher WorkerFetcher, actions TrackerActions) TrackerModel {
	ti := textinput.New()
	ti.CharLimit = 500
	ti.Width = 60

	return TrackerModel{
		masterID: masterID,
		fetcher:  fetcher,
		actions:  actions,
		input:    ti,
	}
}

// refreshWorkers reloads the worker list and clamps the cursor.
func (tm *TrackerModel) refreshWorkers() {
	tm.workers = tm.fetcher(tm.masterID)
	if tm.cursor >= len(tm.workers) {
		tm.cursor = max(0, len(tm.workers)-1)
	}
}

// Update handles key messages for the tracker sub-model.
// Returns the updated model and an optional command.
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
		if tm.cursor < len(tm.workers)-1 {
			tm.cursor++
		}

	case "k", "up":
		if tm.cursor > 0 {
			tm.cursor--
		}

	case "enter":
		if len(tm.workers) > 0 && tm.workers[tm.cursor].Status == "active" {
			tm.lastErr = tm.actions.Attach(ctx, tm.masterID, tm.workers[tm.cursor].ID)
			tm.refreshWorkers()
		}

	case "r":
		if len(tm.workers) > 0 {
			tm.mode = trackerModeRelay
			tm.input.Placeholder = fmt.Sprintf("message to %s...", tm.workers[tm.cursor].ID)
			tm.input.Reset()
			tm.input.Focus()
			return tm, textinput.Blink
		}

	case "b":
		tm.mode = trackerModeBroadcast
		tm.input.Placeholder = "broadcast to all workers..."
		tm.input.Reset()
		tm.input.Focus()
		return tm, textinput.Blink

	case "s":
		tm.mode = trackerModeSpawn
		tm.input.Placeholder = "worker title..."
		tm.input.Reset()
		tm.input.Focus()
		return tm, textinput.Blink

	case "x":
		if len(tm.workers) > 0 {
			tm.lastErr = tm.actions.Stop(ctx, tm.masterID, tm.workers[tm.cursor].ID)
			tm.refreshWorkers()
		}

	case "d":
		if len(tm.workers) > 0 {
			tm.lastErr = tm.actions.Delete(ctx, tm.masterID, tm.workers[tm.cursor].ID)
			tm.refreshWorkers()
		}

	case "m":
		if len(tm.workers) > 0 {
			id := tm.workers[tm.cursor].ID
			j, err := tm.actions.ManifestJSON(id)
			if err != nil {
				tm.lastErr = err
			} else {
				tm.mode = trackerModeManifest
				tm.manifestJSON = j
				tm.manifestID = id
				tm.manifestScrl = 0
			}
		}

	case "M":
		j, err := tm.actions.ManifestJSON(tm.masterID)
		if err != nil {
			tm.lastErr = err
		} else {
			tm.mode = trackerModeManifest
			tm.manifestJSON = j
			tm.manifestID = tm.masterID
			tm.manifestScrl = 0
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
		if val != "" {
			switch tm.mode {
			case trackerModeRelay:
				if len(tm.workers) > 0 {
					tm.lastErr = tm.actions.Relay(ctx, tm.workers[tm.cursor].ID, val)
				}
			case trackerModeBroadcast:
				tm.lastErr = tm.actions.Broadcast(ctx, tm.masterID, val)
			case trackerModeSpawn:
				tm.lastErr = tm.actions.Spawn(ctx, tm.masterID, val)
			}
		}
		tm.mode = trackerModeNormal
		tm.input.Blur()
		// Delayed refresh after action (matches legacy tracker behavior)
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
	// Clamp scroll offset if the manifest shrank since the view was opened.
	if tm.manifestScrl > maxScroll {
		tm.manifestScrl = maxScroll
	}

	switch msg.String() {
	case "esc", "m", "M", "q":
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

// View renders the tracker body (worker list or manifest inspect).
func (tm TrackerModel) View() string {
	if tm.mode == trackerModeManifest {
		return tm.viewManifest()
	}
	return tm.viewWorkers()
}

func (tm TrackerModel) viewWorkers() string {
	outerW, outerH := clampDimensions(tm.width, tm.height)

	compact := outerW > 0 && outerW < compactThreshold
	innerW, _ := contentDimensions(outerW, outerH)
	if innerW < 4 {
		innerW = 4
	}

	// Decide whether to show a status bar (input mode or error in tall panes).
	wantsStatus := tm.lastErr != nil || tm.mode != trackerModeNormal
	_, showStatus := chromeLayout(outerH, wantsStatus)

	// Title: gold "Master" token embedded in border.
	title := masterTitleStyle.Render(LabelMaster) + paneTitleStyle.Render(": "+tm.masterID)

	// Footer: input-mode hints when composing, otherwise steady-state.
	isInputMode := tm.mode != trackerModeNormal && tm.mode != trackerModeManifest
	var footer string
	if isInputMode {
		footer = "⏎ send · esc cancel"
	} else {
		footer = tm.trackerFooter(compact, showStatus)
	}

	// Build body content.
	var body strings.Builder
	workerCount := len(tm.workers)
	if workerCount == 0 {
		body.WriteString(dimTextStyle.Render("No workers. 's' to spawn."))
	} else {
		for i, w := range tm.workers {
			if i > 0 {
				body.WriteString("\n")
			}
			body.WriteString(tm.renderWorkerRow(w, i, compact, innerW))

			if w.Snippet != "" && outerW >= 30 {
				snipStyle := snippetStyleWide
				pad := 3
				if compact {
					snipStyle = snippetStyleNarrow
					pad = 2
				}
				maxSnip := innerW - pad
				if maxSnip < 4 {
					maxSnip = 4
				}
				for _, sline := range strings.Split(w.Snippet, "\n") {
					body.WriteString("\n" + snipStyle.Render(truncate(sline, maxSnip)))
				}
			}
		}
	}

	// Compute pane height, reserving space for composer/status below.
	paneH := outerH
	useBorderedComposer := isInputMode && outerW >= 40 && outerH >= compactHeightThreshold

	if useBorderedComposer {
		paneH -= 3 // bordered composer = 3 rows
	} else if isInputMode {
		paneH-- // inline composer = 1 row
	} else if showStatus {
		paneH-- // status bar = 1 row
	}
	if paneH < 3 {
		paneH = 3
	}
	result := borderedPane(body.String(), title, footer, outerW, paneH, true)

	// Append composer or status bar below the pane.
	if isInputMode {
		result += "\n" + tm.renderComposer(useBorderedComposer, outerW)
	} else if showStatus && tm.lastErr != nil {
		result += "\n" + renderStatusBar(outerW, nil, "", tm.lastErr)
	}

	return result
}

func (tm TrackerModel) renderWorkerRow(w WorkerRow, idx int, compact bool, innerW int) string {
	selected := idx == tm.cursor

	var status string
	if compact {
		if w.Status == "active" {
			status = activeTextStyle.Render("●")
		} else {
			status = errorTextStyle.Render("○")
		}
	} else {
		if w.Status == "active" {
			status = activeTextStyle.Render("● active")
		} else {
			status = errorTextStyle.Render("○ stopped")
		}
	}

	title := workerDisplayName(w.Title, w.ID)
	statusLen := 2
	if !compact {
		statusLen = 10
	}
	maxTitle := innerW - statusLen - 4 // cursor + spacing
	if maxTitle < 4 {
		maxTitle = 4
	}
	title = truncate(title, maxTitle)

	prefix := "  "
	titleStyle := inactiveWorkerTitleStyle
	if selected {
		prefix = "> "
		titleStyle = selectedWorkerTitleStyle
	}

	return fmt.Sprintf("%s%s  %s", prefix, titleStyle.Render(title), status)
}

func (tm TrackerModel) trackerFooter(compact, showStatus bool) string {
	workerCount := len(tm.workers)

	// Fold error into footer when status bar is not available.
	errPrefix := ""
	if tm.lastErr != nil && !showStatus {
		errPrefix = fmt.Sprintf("error: %s · ", tm.lastErr)
	}

	if compact {
		return fmt.Sprintf("%s%dw · j/k ⏎ r b s m x d q", errPrefix, workerCount)
	}
	return fmt.Sprintf("%s%d workers · j/k ⏎ r/b s m/M x/d q", errPrefix, workerCount)
}

// workerDisplayName returns the display label for a worker row.
// Shows "TITLE (ID)" when a title is set, otherwise just the ID.
func workerDisplayName(title, id string) string {
	if title == "" {
		return id
	}
	return fmt.Sprintf("%s (%s)", title, id)
}

func (tm TrackerModel) renderComposer(bordered bool, width int) string {
	var label string
	switch tm.mode {
	case trackerModeRelay:
		label = "relay"
	case trackerModeBroadcast:
		label = "broadcast"
	case trackerModeSpawn:
		label = "spawn"
	}

	inputView := tm.input.View()

	if bordered {
		composerTitle := paneTitleStyle.Render(label)
		composerFooter := "⏎ send · esc cancel"
		content := " " + inputView
		return borderedPane(content, composerTitle, composerFooter, width, 3, true)
	}

	// Inline compact fallback.
	short := string([]rune(label)[0])
	return fmt.Sprintf(" %s> %s", short, inputView)
}

func (tm TrackerModel) viewManifest() string {
	outerW, outerH := clampDimensions(tm.width, tm.height)

	innerW, _ := contentDimensions(outerW, outerH)
	if innerW < 4 {
		innerW = 4
	}

	lines := strings.Split(tm.manifestJSON, "\n")
	viewable := tm.manifestViewable()

	// Clamp scroll offset if the manifest shrank since the view was opened.
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

	// Scroll indicator position: map scroll offset to inner row.
	scrollLine := -1
	if len(lines) > viewable && viewable > 0 {
		scrollLine = tm.manifestScrl * (viewable - 1) / (len(lines) - viewable)
	}

	return borderedPaneWithScroll(body.String(), title, footer, outerW, outerH, true, scrollLine)
}
