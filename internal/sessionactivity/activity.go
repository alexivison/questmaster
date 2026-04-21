package sessionactivity

import (
	"encoding/json"
	"fmt"
	"hash/fnv"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Window keeps a session active briefly after the latest observed primary-pane
// snippet change.
const Window = 3 * time.Second

// Observation is one snippet-bearing session key observed during a refresh.
type Observation struct {
	Key     string
	Snippet string
	Enabled bool
}

// Result is the computed activity status for one observation key.
type Result struct {
	Active       bool
	LastChangeAt time.Time
}

// Entry is the persisted hash/change state for one observation key.
type Entry struct {
	SnippetHash  uint64    `json:"snippet_hash"`
	LastChangeAt time.Time `json:"last_change_at,omitempty"`
}

// State is the persisted cross-invocation activity snapshot.
type State struct {
	Entries map[string]Entry `json:"entries,omitempty"`
}

// PrimaryKey namespaces a session's primary-pane activity key.
func PrimaryKey(sessionID string) string {
	return sessionID + "\x00primary"
}

// Evaluate applies tracker-style snippet-change detection to a fresh set of
// observations and returns the next persisted state plus per-key results.
func Evaluate(now time.Time, observations []Observation, prev State) (State, map[string]Result) {
	next := State{Entries: make(map[string]Entry, len(observations))}
	results := make(map[string]Result, len(observations))

	for _, obs := range observations {
		if obs.Key == "" {
			continue
		}

		if !obs.Enabled {
			results[obs.Key] = Result{}
			continue
		}

		hash := HashSnippet(obs.Snippet)
		entry := Entry{SnippetHash: hash}

		if strings.TrimSpace(obs.Snippet) == "" {
			next.Entries[obs.Key] = entry
			results[obs.Key] = Result{}
			continue
		}

		lastChange := prev.Entries[obs.Key].LastChangeAt
		if prevEntry, ok := prev.Entries[obs.Key]; !ok || prevEntry.SnippetHash != hash {
			lastChange = now
		}
		if !lastChange.IsZero() {
			entry.LastChangeAt = lastChange
		}

		next.Entries[obs.Key] = entry
		results[obs.Key] = Result{
			Active:       !lastChange.IsZero() && now.Sub(lastChange) < Window,
			LastChangeAt: lastChange,
		}
	}

	if len(next.Entries) == 0 {
		next.Entries = nil
	}

	return next, results
}

// Load reads activity state from disk. Missing files are treated as empty state.
func Load(path string) (State, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return State{}, nil
		}
		return State{}, err
	}

	var state State
	if err := json.Unmarshal(data, &state); err != nil {
		return State{}, fmt.Errorf("parse activity state: %w", err)
	}
	return state, nil
}

// Save writes activity state atomically. Empty state removes the file.
func Save(path string, state State) error {
	if len(state.Entries) == 0 {
		if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
			return err
		}
		return nil
	}

	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}

	data, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')

	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}

// HashSnippet returns the persisted hash used for snippet-change detection.
func HashSnippet(snippet string) uint64 {
	h := fnv.New64a()
	_, _ = h.Write([]byte(snippet))
	return h.Sum64()
}
