package tui

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// CodexState represents the Codex process state.
type CodexState string

const (
	CodexWorking CodexState = "working"
	CodexIdle    CodexState = "idle"
	CodexError   CodexState = "error"
	CodexOffline CodexState = "offline" // synthetic: no status file found
)

// staleThreshold is how long a "working" state can persist before we treat it as stale.
const staleThreshold = 30 * time.Minute

// CodexStatus is the domain model for codex-status.json.
type CodexStatus struct {
	State      CodexState `json:"state"`
	Target     string     `json:"target,omitempty"`
	Mode       string     `json:"mode,omitempty"`
	Verdict    string     `json:"verdict,omitempty"`
	StartedAt  string     `json:"started_at,omitempty"`
	FinishedAt string     `json:"finished_at,omitempty"`
	Error      string     `json:"error,omitempty"`
}

// ParseCodexStatus parses raw JSON into a CodexStatus.
func ParseCodexStatus(data []byte) (CodexStatus, error) {
	var cs CodexStatus
	if err := json.Unmarshal(data, &cs); err != nil {
		return CodexStatus{}, fmt.Errorf("parse codex status: %w", err)
	}
	return cs, nil
}

// ReadCodexStatus reads and parses codex-status.json from a runtime directory.
// Returns CodexOffline state (no error) when the file is missing or empty.
// Detects stale "working" states and marks them as errors.
func ReadCodexStatus(runtimeDir string) (CodexStatus, error) {
	path := filepath.Join(runtimeDir, "codex-status.json")

	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return CodexStatus{State: CodexOffline}, nil
		}
		return CodexStatus{}, fmt.Errorf("read codex status: %w", err)
	}

	if len(data) == 0 {
		return CodexStatus{State: CodexOffline}, nil
	}

	cs, err := ParseCodexStatus(data)
	if err != nil {
		return CodexStatus{State: CodexOffline}, nil
	}

	// Detect stale working state
	if cs.State == CodexWorking && cs.StartedAt != "" {
		started, parseErr := time.Parse(time.RFC3339, cs.StartedAt)
		if parseErr == nil && time.Since(started) > staleThreshold {
			cs.State = CodexError
			cs.Error = "stale: started " + cs.StartedAt
		}
	}

	return cs, nil
}

// EvidenceEntry represents one line from the JSONL evidence log.
type EvidenceEntry struct {
	Timestamp string `json:"timestamp"`
	Type      string `json:"type"`
	Result    string `json:"result"`
	DiffHash  string `json:"diff_hash"`
}

// ReadEvidenceSummary reads the last N entries from the evidence JSONL log.
// Returns nil when the file is missing.
func ReadEvidenceSummary(sessionID string, maxEntries int) []EvidenceEntry {
	path := fmt.Sprintf("/tmp/claude-evidence-%s.jsonl", sessionID)

	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()

	var entries []EvidenceEntry
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		var e EvidenceEntry
		if json.Unmarshal(scanner.Bytes(), &e) == nil && e.Type != "" {
			entries = append(entries, e)
		}
	}

	// Keep only the last maxEntries
	if len(entries) > maxEntries {
		entries = entries[len(entries)-maxEntries:]
	}
	return entries
}
