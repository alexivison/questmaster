// Package picker provides fzf-based interactive session selection.
package picker

import (
	"context"
	"errors"
	"fmt"
	"os"
	"sort"
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
	PaneLines    []string // last lines from the primary pane
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
	liveManifests := make([]state.Manifest, 0, len(all))
	for _, m := range all {
		if liveSet[m.PartyID] {
			liveManifests = append(liveManifests, m)
		}
	}
	sort.SliceStable(liveManifests, func(i, j int) bool {
		return stableSessionOrderKey(liveManifests[i]) > stableSessionOrderKey(liveManifests[j])
	})
	liveManifests = orderSessionManifests(liveManifests)

	var entries []Entry

	liveMasterSet := make(map[string]bool, len(liveManifests))
	for _, m := range liveManifests {
		if m.SessionType == "master" {
			liveMasterSet[m.PartyID] = true
		}
	}

	for _, m := range liveManifests {
		parent := m.ExtraString("parent_session")
		entry := Entry{
			SessionID:    m.PartyID,
			Title:        m.Title,
			Cwd:          shortPath(m.Cwd),
			PrimaryAgent: primaryAgentName(m),
		}

		switch {
		case m.SessionType == "master":
			entry.Status = fmt.Sprintf("master (%d)", len(m.Workers))
			if m.PartyID == currentSession {
				entry.Status = fmt.Sprintf("* current master (%d)", len(m.Workers))
			}
		case parent != "" && liveMasterSet[parent]:
			entry.SessionID = "  " + entry.SessionID
			entry.Status = "  worker"
			if m.PartyID == currentSession {
				entry.Status = "* current worker"
			}
		case parent != "":
			entry.Status = "worker (orphan)"
			if m.PartyID == currentSession {
				entry.Status = "* current worker (orphan)"
			}
		default:
			entry.Status = "active"
			if m.PartyID == currentSession {
				entry.Status = "* current"
			}
		}

		entries = append(entries, entry)
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

func stableSessionOrderKey(manifest state.Manifest) string {
	if manifest.CreatedAt != "" {
		return manifest.CreatedAt + "|" + manifest.PartyID
	}
	return manifest.PartyID
}

func orderSessionManifests(manifests []state.Manifest) []state.Manifest {
	order := make(map[string]int, len(manifests))
	byID := make(map[string]state.Manifest, len(manifests))
	children := make(map[string][]state.Manifest)
	masters := make([]state.Manifest, 0, len(manifests))
	standalones := make([]state.Manifest, 0, len(manifests))
	orphans := make([]state.Manifest, 0, len(manifests))

	for i, manifest := range manifests {
		order[manifest.PartyID] = i
		byID[manifest.PartyID] = manifest
	}

	for _, manifest := range manifests {
		parent := manifest.ExtraString("parent_session")
		switch {
		case manifest.SessionType == "master":
			masters = append(masters, manifest)
		case parent != "":
			if _, ok := byID[parent]; ok {
				children[parent] = append(children[parent], manifest)
			} else {
				orphans = append(orphans, manifest)
			}
		default:
			standalones = append(standalones, manifest)
		}
	}

	sortByOrder := func(items []state.Manifest) {
		sort.SliceStable(items, func(i, j int) bool {
			return order[items[i].PartyID] < order[items[j].PartyID]
		})
	}
	sortByOrder(masters)
	sortByOrder(standalones)
	sortByOrder(orphans)
	for parentID := range children {
		sortByOrder(children[parentID])
	}

	ordered := make([]state.Manifest, 0, len(manifests))
	for _, master := range masters {
		ordered = append(ordered, master)
		ordered = append(ordered, children[master.PartyID]...)
	}
	ordered = append(ordered, standalones...)
	ordered = append(ordered, orphans...)
	return ordered
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
	if err := ctx.Err(); err != nil {
		return nil, err
	}

	alive, err := client.HasSession(ctx, sessionID)
	if err != nil && ctx.Err() != nil {
		return nil, ctx.Err()
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}

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
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return pd, nil
	}
	raw, err := client.Capture(ctx, target, 500)
	if err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
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
	alive, err := client.HasSession(ctx, sessionID)
	if err != nil && ctx.Err() != nil {
		return nil, ctx.Err()
	}
	if !alive {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		return nil, nil //nolint:nilnil
	}

	pd := &PreviewData{Status: "tmux"}

	cwd, err := client.SessionCwd(ctx, sessionID)
	if err == nil {
		pd.Cwd = shortPath(cwd)
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}

	// Capture last lines from the active pane (tmux defaults to active window/pane).
	raw, err := client.Capture(ctx, sessionID, 500)
	if err == nil {
		pd.PaneLines = lastNonEmptyLines(raw, 8)
	} else if ctx.Err() != nil {
		return nil, ctx.Err()
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
