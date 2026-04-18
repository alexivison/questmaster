package tui

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
)

// EvidenceEntry represents one line from the JSONL evidence log.
type EvidenceEntry struct {
	Timestamp string `json:"timestamp"`
	Type      string `json:"type"`
	Result    string `json:"result"`
	DiffHash  string `json:"diff_hash"`
}

// evidencePath returns the evidence JSONL path for a session.
func evidencePath(sessionID string) string {
	return fmt.Sprintf("/tmp/claude-evidence-%s.jsonl", sessionID)
}

// readEvidence parses every entry from the evidence JSONL at path.
// Returns nil when the file is missing.
func readEvidence(path string) []EvidenceEntry {
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
	return entries
}

// ReadEvidenceSummary reads the last N entries from the evidence JSONL log.
// Returns nil when the file is missing.
func ReadEvidenceSummary(sessionID string, maxEntries int) []EvidenceEntry {
	entries := readEvidence(evidencePath(sessionID))
	if len(entries) > maxEntries {
		entries = entries[len(entries)-maxEntries:]
	}
	return entries
}
