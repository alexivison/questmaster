package piactivity

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/anthropics/ai-party/tools/party-cli/internal/state"
)

const (
	// Filename is the Pi extension sidecar written under /tmp/<party-id>/.
	Filename = "pi-activity.json"

	// MaxAge is longer than the extension heartbeat interval. A stale sidecar is
	// ignored so a crashed Pi process cannot leave a session blinking forever.
	MaxAge = 10 * time.Second
)

var (
	validPartyID     = regexp.MustCompile(`^party-[A-Za-z0-9_-]+$`)
	piSessionFile    = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-\d{3}Z_([A-Za-z0-9_-]+)\.jsonl$`)
	piSessionUUIDish = regexp.MustCompile(`^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$`)
)

// State is the generic JSON sidecar written by Pi's activity-sidecar
// extension when PI_ACTIVITY_FILE is set.
type State struct {
	Version     int      `json:"version"`
	Source      string   `json:"source,omitempty"`
	Agent       string   `json:"agent,omitempty"` // accepted for older/prototype sidecars
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

// Path returns the sidecar path for a party session ID. Invalid IDs return an
// empty path to avoid path traversal through /tmp.
func Path(sessionID string) string {
	if !validPartyID.MatchString(sessionID) {
		return ""
	}
	return filepath.Join("/tmp", sessionID, Filename)
}

// Read returns a fresh Pi activity sidecar snapshot. Missing, malformed,
// mismatched, or stale sidecars return ok=false.
func Read(sessionID string, now time.Time) (Snapshot, bool) {
	snapshot, ok := ReadLatest(sessionID)
	if !ok {
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

// ReadLatest returns the most recent valid Pi sidecar snapshot, even when it is
// too old to be trusted for live activity. Consumers can use this to keep the
// last useful snippet visible without keeping a crashed session active.
func ReadLatest(sessionID string) (Snapshot, bool) {
	path := Path(sessionID)
	if path == "" {
		return Snapshot{}, false
	}

	data, err := os.ReadFile(path)
	if err != nil {
		return Snapshot{}, false
	}

	var state State
	if err := json.Unmarshal(data, &state); err != nil {
		return Snapshot{}, false
	}
	if state.Version != 1 || state.UpdatedAtMS <= 0 {
		return Snapshot{}, false
	}
	if state.Source != "pi" && state.Agent != "pi" {
		return Snapshot{}, false
	}
	stateID := state.ID
	if stateID == "" {
		stateID = state.SessionID
	}
	if stateID != "" && stateID != sessionID {
		return Snapshot{}, false
	}

	return Snapshot{
		Busy:        state.Busy,
		Phase:       state.Phase,
		Snippet:     strings.TrimSpace(state.Snippet),
		Recent:      cleanRecent(state.Recent),
		UpdatedAt:   time.UnixMilli(state.UpdatedAtMS),
		SessionFile: strings.TrimSpace(state.SessionFile),
		ResumeID:    ResumeIDFromState(state),
	}, true
}

// ReadResumeID returns the Pi resume UUID observed in the latest sidecar.
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
