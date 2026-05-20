package piactivity

import (
	"encoding/json"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/anthropics/ai-party/tools/party-cli/internal/state"
)

const (
	// Filename is the transitional state snapshot filename used by the Phase 2
	// adapter. The legacy pi-activity.json reader was removed; callers should
	// treat this package as a read-only view over state.json.
	Filename = "state.json"

	// MaxAge is longer than the Pi sidecar heartbeat interval. A stale snapshot is
	// ignored for live activity so a crashed Pi process cannot leave a session
	// blinking forever.
	MaxAge = 10 * time.Second
)

var (
	piSessionFile    = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-\d{3}Z_([A-Za-z0-9_-]+)\.jsonl$`)
	piSessionUUIDish = regexp.MustCompile(`^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$`)
)

// State is retained for tests and Phase 2 callers that construct canned Pi
// activity fixtures. MarshalJSON writes the state.json shape now consumed by the
// adapter rather than the removed legacy pi-activity.json shape.
type State struct {
	Version     int      `json:"version"`
	Source      string   `json:"source,omitempty"`
	Agent       string   `json:"agent,omitempty"`
	ID          string   `json:"id,omitempty"`
	SessionID   string   `json:"session_id,omitempty"`
	PiSessionID string   `json:"pi_session_id,omitempty"`
	SessionFile string   `json:"session_file,omitempty"`
	UpdatedAtMS int64    `json:"updated_at_ms"`
	Busy        bool     `json:"busy"`
	Phase       string   `json:"phase,omitempty"`
	Snippet     string   `json:"snippet,omitempty"`
	Recent      []string `json:"recent,omitempty"`
}

// MarshalJSON preserves existing fixture helpers while emitting state.json.
func (activity State) MarshalJSON() ([]byte, error) {
	sessionID := activity.ID
	if sessionID == "" {
		sessionID = activity.SessionID
	}
	updatedAt := time.UnixMilli(activity.UpdatedAtMS).UTC()
	pane := state.PaneState{
		Role:        "primary",
		Agent:       "pi",
		State:       stateFromActivity(activity),
		Activity:    strings.TrimSpace(activity.Snippet),
		Seq:         updatedAt.UnixNano(),
		LastEvent:   updatedAt,
		LastKind:    strings.TrimSpace(activity.Phase),
		Recent:      cleanRecent(activity.Recent),
		SessionFile: strings.TrimSpace(activity.SessionFile),
		PiSessionID: strings.TrimSpace(activity.PiSessionID),
	}
	return json.Marshal(state.SessionState{
		SessionID: sessionID,
		Version:   state.SchemaVersion,
		SeenAt:    updatedAt,
		Panes: map[string]state.PaneState{
			"primary": pane,
		},
	})
}

// Snapshot is a validated activity observation for a Pi party session.
type Snapshot struct {
	Busy        bool
	Phase       string
	Snippet     string
	Recent      []string
	UpdatedAt   time.Time
	SessionFile string
	ResumeID    string
}

// Path returns the state.json path for a party session ID. Invalid IDs return an
// empty path to avoid path traversal through the state root.
func Path(sessionID string) string {
	if !state.IsValidPartyID(sessionID) {
		return ""
	}
	root := state.StateRoot()
	if root == "" {
		return ""
	}
	return state.SessionStatePath(root, sessionID)
}

// Read returns a fresh Pi activity snapshot from state.json. Missing,
// malformed, mismatched, or stale snapshots return ok=false.
func Read(sessionID string, now time.Time) (Snapshot, bool) {
	snapshot, ok := ReadLatest(sessionID)
	if !ok || snapshot.UpdatedAt.IsZero() {
		return Snapshot{}, false
	}
	if now.IsZero() {
		now = time.Now()
	}
	if now.Sub(snapshot.UpdatedAt) > MaxAge || snapshot.UpdatedAt.Sub(now) > MaxAge {
		return Snapshot{}, false
	}
	return snapshot, true
}

// ReadLatest returns the most recent valid Pi snapshot, even when it is too old
// to be trusted for live activity. Consumers can use this to keep the last
// useful snippet visible without keeping a crashed session active.
func ReadLatest(sessionID string) (Snapshot, bool) {
	ss, err := state.LoadSessionState(sessionID)
	if err != nil || ss == nil || ss.Version != state.SchemaVersion {
		return Snapshot{}, false
	}
	pane, ok := ss.Panes["primary"]
	if !ok {
		return Snapshot{}, false
	}
	if pane.Agent != "" && pane.Agent != "pi" {
		return Snapshot{}, false
	}
	return snapshotFromPane(pane, ss.SeenAt), true
}

// ReadResumeID returns the Pi resume UUID observed in the latest state.json.
func ReadResumeID(sessionID string) (string, bool) {
	snapshot, ok := ReadLatest(sessionID)
	if !ok || snapshot.ResumeID == "" {
		return "", false
	}
	return snapshot.ResumeID, true
}

// ResumeIDFromState derives Pi's resume UUID from trusted activity fields.
func ResumeIDFromState(activity State) string {
	if id := cleanPiResumeID(activity.PiSessionID); id != "" {
		return id
	}
	return ResumeIDFromSessionFile(activity.SessionFile)
}

// ResumeIDFromSessionFile extracts the UUID from Pi session files named
// <timestamp>_<uuid>.jsonl. Invalid or non-UUID-shaped values return empty.
func ResumeIDFromSessionFile(sessionFile string) string {
	sessionFile = strings.TrimSpace(sessionFile)
	if sessionFile == "" {
		return ""
	}
	base := filepath.Base(sessionFile)
	match := piSessionFile.FindStringSubmatch(base)
	if len(match) != 2 {
		return ""
	}
	return cleanPiResumeID(match[1])
}

func snapshotFromPane(pane state.PaneState, seenAt time.Time) Snapshot {
	updatedAt := pane.LastEvent
	if updatedAt.IsZero() {
		updatedAt = seenAt
	}
	return Snapshot{
		Busy:        pane.State == "starting" || pane.State == "working" || pane.State == "blocked",
		Phase:       strings.TrimSpace(pane.State),
		Snippet:     strings.TrimSpace(pane.Activity),
		Recent:      cleanRecent(pane.Recent),
		UpdatedAt:   updatedAt,
		SessionFile: strings.TrimSpace(pane.SessionFile),
		ResumeID:    resumeIDFromPane(pane),
	}
}

func resumeIDFromPane(pane state.PaneState) string {
	if id := cleanPiResumeID(pane.PiSessionID); id != "" {
		return id
	}
	return ResumeIDFromSessionFile(pane.SessionFile)
}

func stateFromActivity(activity State) string {
	phase := strings.TrimSpace(activity.Phase)
	if activity.Busy {
		return "working"
	}
	switch phase {
	case "done", "idle", "stopped", "starting", "blocked", "working":
		return phase
	case "":
		return "idle"
	default:
		return phase
	}
}

func cleanPiResumeID(id string) string {
	id = strings.TrimSpace(id)
	if id == "" || !piSessionUUIDish.MatchString(id) {
		return ""
	}
	return state.SanitizeResumeID(id)
}

func cleanRecent(lines []string) []string {
	clean := make([]string, 0, len(lines))
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		clean = append(clean, line)
	}
	return clean
}
