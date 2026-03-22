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
			tm.lastErr = tm.actions.Attach(ctx, tm.workers[tm.cursor].ID)
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
			tm.lastErr = tm.actions.Stop(ctx, tm.workers[tm.cursor].ID)
			tm.refreshWorkers()
		}

	case "d":
		if len(tm.workers) > 0 {
			tm.lastErr = tm.actions.Delete(ctx, tm.workers[tm.cursor].ID)
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

func (tm TrackerModel) updateManifest(msg tea.KeyMsg) (TrackerModel, tea.Cmd) {
	lines := strings.Split(tm.manifestJSON, "\n")
	viewable := tm.height - 6
	if viewable < 1 {
		viewable = 1
	}
	maxScroll := len(lines) - viewable
	if maxScroll < 0 {
		maxScroll = 0
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

func (tm TrackerModel) innerWidth() int {
	w := tm.width - 4
	if w < 10 {
		w = 10
	}
	return w
}

func (tm TrackerModel) viewWorkers() string {
	var b strings.Builder
	inner := tm.innerWidth()
	compact := tm.width > 0 && tm.width < compactThreshold

	// Header
	workerCount := len(tm.workers)
	if compact {
		b.WriteString(titleStyle.Render(truncate(fmt.Sprintf(" %s", tm.masterID), inner)) + "\n")
		b.WriteString(dimStyle.Render(fmt.Sprintf(" %dw", workerCount)) + "\n")
	} else {
		header := titleStyle.Render(fmt.Sprintf("  Master: %s", tm.masterID))
		count := dimStyle.Render(fmt.Sprintf("  %d worker(s)", workerCount))
		b.WriteString(header + count + "\n")
	}
	b.WriteString(headerRule.Render("  " + strings.Repeat("\u2500", inner)) + "\n\n")

	// Worker list
	if workerCount == 0 {
		b.WriteString(dimStyle.Render("  No workers. 's' to spawn.") + "\n")
	} else {
		for i, w := range tm.workers {
			cursor := "  "
			nameStyle := dimStyle
			if i == tm.cursor {
				cursor = selectedStyle.Render("▸ ")
				nameStyle = selectedStyle
			}

			var status string
			if compact {
				if w.Status == "active" {
					status = activeStyle.Render("●")
				} else {
					status = stoppedStyle.Render("○")
				}
			} else {
				if w.Status == "active" {
					status = activeStyle.Render("● active")
				} else {
					status = stoppedStyle.Render("○ stopped")
				}
			}

			title := w.Title
			if title == "" {
				title = w.ID
			}
			statusLen := 2
			if !compact {
				statusLen = 10
			}
			maxTitle := inner - statusLen
			if maxTitle < 4 {
				maxTitle = 4
			}
			title = truncate(title, maxTitle)

			line := fmt.Sprintf("%s%s  %s", cursor, nameStyle.Render(title), status)
			b.WriteString(line + "\n")

			// Snippet — skip in very narrow panes
			if w.Snippet != "" && tm.width >= 30 {
				snipStyle := snippetStyleWide
				pad := 6
				if compact {
					snipStyle = snippetStyleNarrow
					pad = 3
				}
				maxSnip := inner - pad
				for _, sline := range strings.Split(w.Snippet, "\n") {
					b.WriteString(snipStyle.Render(truncate(sline, maxSnip)) + "\n")
				}
			}

			b.WriteString("\n")
		}
	}

	// Footer
	b.WriteString(headerRule.Render("  " + strings.Repeat("\u2500", inner)) + "\n")

	if tm.lastErr != nil {
		b.WriteString(stoppedStyle.Render(fmt.Sprintf("  error: %s", tm.lastErr)) + "\n")
	}

	if tm.mode != trackerModeNormal {
		var label string
		switch tm.mode {
		case trackerModeRelay:
			label = "r"
		case trackerModeBroadcast:
			label = "b"
		case trackerModeSpawn:
			label = "s"
		}
		b.WriteString(fmt.Sprintf(" %s> %s\n", label, tm.input.View()))
		b.WriteString(footerStyle.Render(" \u23ce:send esc:cancel") + "\n")
	} else if compact {
		b.WriteString(footerStyle.Render(" j/k \u23ce r b s m M x d q") + "\n")
	} else {
		b.WriteString(footerStyle.Render("  j/k:nav  \u23ce:attach  r/b:relay  s:spawn  m/M:manifest  x/d:stop  q:quit") + "\n")
	}

	return b.String()
}

func (tm TrackerModel) viewManifest() string {
	var b strings.Builder
	inner := tm.innerWidth()

	b.WriteString(titleStyle.Render(fmt.Sprintf("  Manifest: %s", truncate(tm.manifestID, inner-12))) + "\n")
	b.WriteString(headerRule.Render("  "+strings.Repeat("\u2500", inner)) + "\n")

	lines := strings.Split(tm.manifestJSON, "\n")
	viewable := tm.height - 6
	if viewable < 1 {
		viewable = 1
	}

	end := tm.manifestScrl + viewable
	if end > len(lines) {
		end = len(lines)
	}
	for _, line := range lines[tm.manifestScrl:end] {
		b.WriteString("  " + truncate(line, inner) + "\n")
	}

	b.WriteString(headerRule.Render("  "+strings.Repeat("\u2500", inner)) + "\n")
	scrollInfo := ""
	if len(lines) > viewable {
		scrollInfo = fmt.Sprintf("  [%d/%d]  ", tm.manifestScrl+1, len(lines))
	}
	b.WriteString(footerStyle.Render(scrollInfo+"j/k:scroll  esc:back") + "\n")

	return b.String()
}
