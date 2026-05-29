// Package picker provides interactive session selection.
package picker

import (
	"context"
	"fmt"
	"os"
	"sort"
	"strings"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
)

// Entry represents a single row in the picker display.
type Entry struct {
	SessionID    string
	Status       string // "active", "* current", "master (N)", "worker", "worker (orphan)", "resumable"
	Title        string
	Cwd          string
	SessionType  string
	PrimaryAgent string
	IsSep        bool // separator line between active and resumable
}

// BuildEntries constructs picker rows from discovery and tmux state.
// Rows are grouped as standalone sessions, masters with workers, orphans, then stale sessions.
func BuildEntries(ctx context.Context, store *state.Store, client *tmux.Client) ([]Entry, error) {
	live, err := client.ListSessions(ctx)
	if err != nil {
		return nil, fmt.Errorf("list tmux sessions: %w", err)
	}

	liveSet := make(map[string]bool, len(live))
	for _, s := range live {
		if state.IsValidSessionID(s) {
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
		if liveSet[m.SessionID] {
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
			liveMasterSet[m.SessionID] = true
		}
	}

	for _, m := range liveManifests {
		parent := m.ExtraString("parent_session")
		entry := Entry{
			SessionID:    m.SessionID,
			Title:        m.Title,
			Cwd:          shortPath(m.Cwd),
			SessionType:  normalizedSessionType(m.SessionType),
			PrimaryAgent: primaryAgentName(m),
		}

		switch {
		case m.SessionType == "master":
			entry.SessionType = "master"
			entry.Status = fmt.Sprintf("master (%d)", len(m.Workers))
			if m.SessionID == currentSession {
				entry.Status = fmt.Sprintf("* current master (%d)", len(m.Workers))
			}
		case parent != "" && liveMasterSet[parent]:
			entry.SessionType = "worker"
			entry.SessionID = "  " + entry.SessionID
			entry.Status = "  worker"
			if m.SessionID == currentSession {
				entry.Status = "* current worker"
			}
		case parent != "":
			entry.SessionType = "worker"
			entry.Status = "worker (orphan)"
			if m.SessionID == currentSession {
				entry.Status = "* current worker (orphan)"
			}
		default:
			entry.Status = "active"
			if m.SessionID == currentSession {
				entry.Status = "* current"
			}
		}

		entries = append(entries, entry)
	}

	// Stale (resumable) sessions.
	var stale []state.Manifest
	for _, m := range all {
		if !liveSet[m.SessionID] {
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
			sessionType := normalizedSessionType(m.SessionType)
			if m.ExtraString("parent_session") != "" {
				sessionType = "worker"
			}
			entries = append(entries, Entry{
				SessionID:    m.SessionID,
				Status:       shortTS(ts),
				Title:        m.Title,
				Cwd:          shortPath(m.Cwd),
				SessionType:  sessionType,
				PrimaryAgent: primaryAgentName(m),
			})
		}
	}

	return entries, nil
}

func stableSessionOrderKey(manifest state.Manifest) string {
	if manifest.CreatedAt != "" {
		return manifest.CreatedAt + "|" + manifest.SessionID
	}
	return manifest.SessionID
}

func orderSessionManifests(manifests []state.Manifest) []state.Manifest {
	order := make(map[string]int, len(manifests))
	byID := make(map[string]state.Manifest, len(manifests))
	children := make(map[string][]state.Manifest)
	topLevel := make([]state.Manifest, 0, len(manifests))
	orphans := make([]state.Manifest, 0, len(manifests))

	for i, manifest := range manifests {
		order[manifest.SessionID] = i
		byID[manifest.SessionID] = manifest
	}

	for _, manifest := range manifests {
		parent := manifest.ExtraString("parent_session")
		switch {
		case manifest.SessionType == "master":
			topLevel = append(topLevel, manifest)
		case parent != "":
			if _, ok := byID[parent]; ok {
				children[parent] = append(children[parent], manifest)
			} else {
				orphans = append(orphans, manifest)
			}
		default:
			topLevel = append(topLevel, manifest)
		}
	}

	sortByOrder := func(items []state.Manifest) {
		sort.SliceStable(items, func(i, j int) bool {
			return order[items[i].SessionID] < order[items[j].SessionID]
		})
	}
	sortByOrder(topLevel)
	sortByOrder(orphans)
	for parentID := range children {
		sortByOrder(children[parentID])
	}

	ordered := make([]state.Manifest, 0, len(manifests))
	for _, manifest := range topLevel {
		ordered = append(ordered, manifest)
		if manifest.SessionType == "master" {
			ordered = append(ordered, children[manifest.SessionID]...)
		}
	}
	ordered = append(ordered, orphans...)
	return ordered
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

func normalizedSessionType(sessionType string) string {
	if sessionType == "" {
		return "standalone"
	}
	return sessionType
}
