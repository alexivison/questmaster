// Package claudetodos reads Claude TodoWrite state files and builds the
// compact overlay summary rendered in the party tracker.
//
// The on-disk file is `~/.claude/todos/<id>-agent-<id>.json` and holds a
// JSON array of `{content, status, ...}` objects. Unknown fields are
// ignored so forward-compatible schema additions don't break parsing.
package claudetodos

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/anthropics/ai-party/tools/party-cli/internal/state"
)

// Status values accepted by the TodoWrite tool.
const (
	StatusPending    = "pending"
	StatusInProgress = "in_progress"
	StatusCompleted  = "completed"
)

// todoFileName is the canonical file suffix Claude Code writes for each
// agent's TodoWrite state.
const todoFileName = "%s-agent-%s.json"

// Item is one todo entry from the TodoWrite payload.
type Item struct {
	Content string `json:"content"`
	Status  string `json:"status"`
}

// Counts tallies items by status.
type Counts struct {
	Pending    int
	InProgress int
	Completed  int
}

// State is the parsed todo state.
type State struct {
	Items  []Item
	Counts Counts
}

// Total returns the item count.
func (s State) Total() int { return len(s.Items) }

// Overlay is the pre-rendered summary for one tracker row.
type Overlay struct {
	Completed   int
	Total       int
	ActiveCount int // in_progress count
	Text        string
}

// FormatLine renders the overlay as the single-line string the tracker
// paints below the snippet. Callers are responsible for prefix/styling.
//
//	1/3: write tests          — single active (or pending/completed)
//	0/5(+2): audit fixtures   — multi active: N = active_count - 1
func (o Overlay) FormatLine() string {
	if o.ActiveCount >= 2 {
		return fmt.Sprintf("%d/%d(+%d): %s", o.Completed, o.Total, o.ActiveCount-1, o.Text)
	}
	return fmt.Sprintf("%d/%d: %s", o.Completed, o.Total, o.Text)
}

// Parse decodes the JSON payload. Malformed JSON returns an error and no
// state — callers should keep their prior good state.
func Parse(data []byte) (State, error) {
	var items []Item
	if err := json.Unmarshal(data, &items); err != nil {
		return State{}, fmt.Errorf("decode todos: %w", err)
	}

	state := State{Items: items}
	for _, it := range items {
		switch it.Status {
		case StatusInProgress:
			state.Counts.InProgress++
		case StatusCompleted:
			state.Counts.Completed++
		case StatusPending:
			state.Counts.Pending++
		}
	}
	return state, nil
}

// BuildOverlay picks the text to show and returns (overlay, true) when the
// state has any item. An empty list returns (Overlay{}, false).
//
// Text pick order: first in_progress → first pending → last completed.
func BuildOverlay(state State) (Overlay, bool) {
	if len(state.Items) == 0 {
		return Overlay{}, false
	}
	ov := Overlay{
		Completed:   state.Counts.Completed,
		Total:       len(state.Items),
		ActiveCount: state.Counts.InProgress,
	}
	for _, it := range state.Items {
		if it.Status == StatusInProgress {
			ov.Text = it.Content
			return ov, true
		}
	}
	for _, it := range state.Items {
		if it.Status == StatusPending {
			ov.Text = it.Content
			return ov, true
		}
	}
	for i := len(state.Items) - 1; i >= 0; i-- {
		if state.Items[i].Status == StatusCompleted {
			ov.Text = state.Items[i].Content
			return ov, true
		}
	}
	return Overlay{}, false
}

// BaseDir returns the canonical todos directory: $HOME/.claude/todos.
func BaseDir() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("resolve home dir: %w", err)
	}
	return filepath.Join(home, ".claude", "todos"), nil
}

// Path returns the absolute path to a session's todo file. sessionID is
// assumed to be pre-sanitised.
func Path(baseDir, sessionID string) string {
	return filepath.Join(baseDir, fmt.Sprintf(todoFileName, sessionID, sessionID))
}

// ResolveSessionID returns the Claude session ID for a party session.
// Priority: resumeFilePath → manifest value → primary-agent resume ID.
// An empty resumeFilePath skips the file lookup. Unsafe IDs (path
// traversal, glob metacharacters) are rejected silently via the shared
// state.SanitizeResumeID guard. Returns "" if no source yields a valid ID.
func ResolveSessionID(resumeFilePath, manifestSessionID, primaryResumeID string) string {
	if resumeFilePath != "" {
		if data, err := os.ReadFile(resumeFilePath); err == nil {
			if id := state.SanitizeResumeID(strings.TrimSpace(string(data))); id != "" {
				return id
			}
		}
	}
	if id := state.SanitizeResumeID(manifestSessionID); id != "" {
		return id
	}
	return state.SanitizeResumeID(primaryResumeID)
}
