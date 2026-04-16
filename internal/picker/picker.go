// Package picker provides fzf-based interactive session selection.
package picker

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"

	"github.com/anthropics/ai-party/tools/party-cli/internal/state"
	"github.com/anthropics/ai-party/tools/party-cli/internal/tmux"
)

// Entry represents a single row in the picker display.
type Entry struct {
	SessionID    string
	Status       string // "active", "* current", "master (N)", "worker", "worker (orphan)", "resumable", "tmux", "* current tmux"
	Title        string
	Cwd          string
	PrimaryAgent string
	IsSep        bool // separator line between active and resumable
}

// PreviewData holds the information rendered in the fzf preview pane.
type PreviewData struct {
	Status       string // "master", "active", "resumable", "tmux"
	WorkerCount  int
	Cwd          string
	Timestamp    string
	PrimaryAgent string
	Prompt       string
	ClaudeID     string
	CodexID      string
	PaneLines    []string // last lines from Claude pane
}

// BuildEntries constructs picker rows from discovery and tmux state.
// Mirrors the hierarchy from party-picker.sh: standalone, masters with workers, orphans, then stale.
func BuildEntries(ctx context.Context, store *state.Store, client *tmux.Client) ([]Entry, error) {
	live, err := client.ListSessions(ctx)
	if err != nil {
		return nil, fmt.Errorf("list tmux sessions: %w", err)
	}

	liveSet := make(map[string]bool, len(live))
	for _, s := range live {
		if strings.HasPrefix(s, "party-") {
			liveSet[s] = true
		}
	}

	currentSession, _ := client.CurrentSessionName(ctx)

	all, err := store.DiscoverSessions()
	if err != nil {
		return nil, fmt.Errorf("discover sessions: %w", err)
	}
	manifestIdx := make(map[string]state.Manifest, len(all))
	for _, m := range all {
		manifestIdx[m.PartyID] = m
	}

	// Classify live sessions.
	var masters, standalone, workers []string
	workerParent := make(map[string]string)
	for _, id := range live {
		if !strings.HasPrefix(id, "party-") {
			continue
		}
		m := manifestIdx[id]
		parent := m.ExtraString("parent_session")
		switch {
		case m.SessionType == "master":
			masters = append(masters, id)
		case parent != "":
			workers = append(workers, id)
			workerParent[id] = parent
		default:
			standalone = append(standalone, id)
		}
	}

	masterSet := make(map[string]bool, len(masters))
	for _, id := range masters {
		masterSet[id] = true
	}

	var entries []Entry

	// Standalone first.
	for _, id := range standalone {
		m := manifestIdx[id]
		status := "active"
		if id == currentSession {
			status = "* current"
		}
		entries = append(entries, Entry{
			SessionID:    id,
			Status:       status,
			Title:        m.Title,
			Cwd:          shortPath(m.Cwd),
			PrimaryAgent: primaryAgentName(m),
		})
	}

	// Masters with their workers indented.
	for _, id := range masters {
		m := manifestIdx[id]
		wc := len(m.Workers)
		status := fmt.Sprintf("master (%d)", wc)
		if id == currentSession {
			status = fmt.Sprintf("* current master (%d)", wc)
		}
		entries = append(entries, Entry{
			SessionID:    id,
			Status:       status,
			Title:        m.Title,
			Cwd:          shortPath(m.Cwd),
			PrimaryAgent: primaryAgentName(m),
		})

		for _, wid := range workers {
			if workerParent[wid] != id {
				continue
			}
			wm := manifestIdx[wid]
			ws := "  worker"
			if wid == currentSession {
				ws = "* current worker"
			}
			// Indent worker session ID to preserve hierarchical display under master.
			entries = append(entries, Entry{
				SessionID:    "  " + wid,
				Status:       ws,
				Title:        wm.Title,
				Cwd:          shortPath(wm.Cwd),
				PrimaryAgent: primaryAgentName(wm),
			})
		}
	}

	// Orphan workers (parent not live).
	for _, wid := range workers {
		if masterSet[workerParent[wid]] {
			continue
		}
		wm := manifestIdx[wid]
		ws := "worker (orphan)"
		if wid == currentSession {
			ws = "* current worker (orphan)"
		}
		entries = append(entries, Entry{
			SessionID:    wid,
			Status:       ws,
			Title:        wm.Title,
			Cwd:          shortPath(wm.Cwd),
			PrimaryAgent: primaryAgentName(wm),
		})
	}

	// Stale (resumable) sessions.
	var stale []state.Manifest
	for _, m := range all {
		if !liveSet[m.PartyID] {
			stale = append(stale, m)
		}
	}
	if len(stale) > 0 {
		state.SortByMtime(stale, store.Root())
		if len(entries) > 0 {
			entries = append(entries, Entry{IsSep: true})
		}
		for _, m := range stale {
			ts := m.ExtraString("last_started_at")
			if ts == "" {
				ts = m.CreatedAt
			}
			entries = append(entries, Entry{
				SessionID:    m.PartyID,
				Status:       shortTS(ts),
				Title:        m.Title,
				Cwd:          shortPath(m.Cwd),
				PrimaryAgent: primaryAgentName(m),
			})
		}
	}

	return entries, nil
}

// BuildTmuxEntries returns picker entries for non-party tmux sessions.
func BuildTmuxEntries(ctx context.Context, client *tmux.Client, currentSession string) ([]Entry, error) {
	details, err := client.ListSessionDetails(ctx)
	if err != nil {
		return nil, fmt.Errorf("list session details: %w", err)
	}

	var entries []Entry
	for _, d := range details {
		if strings.HasPrefix(d.Name, "party-") {
			continue
		}
		status := "tmux"
		if d.Name == currentSession {
			status = "* current tmux"
		}
		entries = append(entries, Entry{
			SessionID: d.Name,
			Status:    status,
			Title:     d.Name,
			Cwd:       shortPath(d.Cwd),
		})
	}
	return entries, nil
}

// BuildPreview generates preview data for a single session.
// Returns nil for non-session tokens (e.g. separator rows from fzf).
func BuildPreview(ctx context.Context, sessionID string, store *state.Store, client *tmux.Client) (*PreviewData, error) {
	if !strings.HasPrefix(sessionID, "party-") {
		return buildTmuxPreview(ctx, sessionID, client)
	}
	m, err := store.Read(sessionID)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, fmt.Errorf("read manifest: %w", err)
	}

	alive, _ := client.HasSession(ctx, sessionID)

	pd := &PreviewData{
		Cwd:          shortPath(m.Cwd),
		PrimaryAgent: primaryAgentName(m),
		Prompt:       m.ExtraString("initial_prompt"),
		ClaudeID:     m.ExtraString("claude_session_id"),
		CodexID:      m.ExtraString("codex_thread_id"),
	}

	ts := m.ExtraString("last_started_at")
	if ts == "" {
		ts = m.CreatedAt
	}
	pd.Timestamp = ts

	switch {
	case alive && m.SessionType == "master":
		pd.Status = "master"
		pd.WorkerCount = len(m.Workers)
	case alive:
		pd.Status = "active"
	default:
		pd.Status = "resumable"
		return pd, nil
	}

	// Capture last lines from the worker's primary pane.
	target, err := client.ResolveRole(ctx, sessionID, "primary", tmux.WindowWorkspace)
	if err != nil {
		return pd, nil
	}
	raw, err := client.Capture(ctx, target, 500)
	if err != nil {
		return pd, nil
	}
	pd.PaneLines = tmux.FilterAgentLines(raw, 8)

	return pd, nil
}

func shortPath(p string) string {
	home, _ := os.UserHomeDir()
	if home != "" && strings.HasPrefix(p, home) {
		return "~" + p[len(home):]
	}
	return p
}

func shortTS(ts string) string {
	if ts == "" || ts == "-" {
		return "-"
	}
	if len(ts) >= 10 {
		return ts[5:7] + "/" + ts[8:10]
	}
	return ts
}

func primaryAgentName(m state.Manifest) string {
	for _, agent := range m.Agents {
		if agent.Role == "primary" && agent.Name != "" {
			return agent.Name
		}
	}
	return ""
}

// buildTmuxPreview generates a preview for a non-party tmux session.
func buildTmuxPreview(ctx context.Context, sessionID string, client *tmux.Client) (*PreviewData, error) {
	alive, _ := client.HasSession(ctx, sessionID)
	if !alive {
		return nil, nil //nolint:nilnil
	}

	pd := &PreviewData{Status: "tmux"}

	cwd, err := client.SessionCwd(ctx, sessionID)
	if err == nil {
		pd.Cwd = shortPath(cwd)
	}

	// Capture last lines from the active pane (tmux defaults to active window/pane).
	raw, err := client.Capture(ctx, sessionID, 500)
	if err == nil {
		pd.PaneLines = lastNonEmptyLines(raw, 8)
	}

	return pd, nil
}

// lastNonEmptyLines returns the last max non-empty lines from raw text.
func lastNonEmptyLines(raw string, max int) []string {
	lines := strings.Split(raw, "\n")
	var result []string
	for _, l := range lines {
		trimmed := strings.TrimRight(l, " ")
		if trimmed != "" {
			result = append(result, trimmed)
		}
	}
	if len(result) > max {
		result = result[len(result)-max:]
	}
	return result
}
