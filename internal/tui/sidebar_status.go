package tui

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// CompanionState represents the companion agent state.
type CompanionState string

const (
	CompanionWorking CompanionState = "working"
	CompanionIdle    CompanionState = "idle"
	CompanionError   CompanionState = "error"
	CompanionOffline CompanionState = "offline" // synthetic: no status file found
)

// staleThreshold is how long a "working" state can persist before we treat it as stale.
const staleThreshold = 30 * time.Minute

// CompanionStatus is the normalized companion state payload.
type CompanionStatus struct {
	State      CompanionState `json:"state"`
	Target     string         `json:"target,omitempty"`
	Mode       string         `json:"mode,omitempty"`
	Verdict    string         `json:"verdict,omitempty"`
	StartedAt  string         `json:"started_at,omitempty"`
	FinishedAt string         `json:"finished_at,omitempty"`
	Error      string         `json:"error,omitempty"`
}

// ParseCompanionStatus parses raw JSON into a CompanionStatus.
func ParseCompanionStatus(data []byte) (CompanionStatus, error) {
	var cs CompanionStatus
	if err := json.Unmarshal(data, &cs); err != nil {
		return CompanionStatus{}, fmt.Errorf("parse companion status: %w", err)
	}
	return cs, nil
}

// ReadCompanionStatus reads a role-specific state file from the runtime directory.
// Returns CompanionOffline (no error) when the file is missing or empty.
func ReadCompanionStatus(runtimeDir, stateFileName string) (CompanionStatus, error) {
	if stateFileName == "" {
		return CompanionStatus{State: CompanionOffline}, nil
	}

	data, err := os.ReadFile(filepath.Join(runtimeDir, stateFileName))
	if err != nil {
		if os.IsNotExist(err) {
			return CompanionStatus{State: CompanionOffline}, nil
		}
		return CompanionStatus{}, fmt.Errorf("read companion status: %w", err)
	}
	if len(data) == 0 {
		return CompanionStatus{State: CompanionOffline}, nil
	}

	cs, err := ParseCompanionStatus(data)
	if err != nil || cs.State == "" {
		return CompanionStatus{State: CompanionOffline}, nil
	}

	if cs.State == CompanionWorking && cs.StartedAt != "" {
		started, parseErr := time.Parse(time.RFC3339, cs.StartedAt)
		if parseErr == nil && time.Since(started) > staleThreshold {
			cs.State = CompanionError
			cs.Error = "stale: started " + cs.StartedAt
		}
	}

	return cs, nil
}

// ReadPrimaryState reads the hook-backed Claude primary state for v1 compatibility.
// Non-Claude primaries should skip this and report an empty state.
func ReadPrimaryState(runtimeDir string) string {
	data, err := os.ReadFile(filepath.Join(runtimeDir, "claude-state.json"))
	if err != nil || len(data) == 0 {
		return ""
	}

	var payload struct {
		State string `json:"state"`
	}
	if json.Unmarshal(data, &payload) != nil {
		return ""
	}
	return payload.State
}

// EvidenceEntry represents one line from the JSONL evidence log.
type EvidenceEntry struct {
	Timestamp string `json:"timestamp"`
	Type      string `json:"type"`
	Result    string `json:"result"`
	DiffHash  string `json:"diff_hash"`
}

// WorkflowStage labels displayed in the tracker.
const (
	StageTesting   = "● testing"
	StageChecks    = "● checks"
	StageCritics   = "● critics"
	StageCriticsOK = "● critics ✓"
	StageCodex     = "● codex"
	StageCodexOK   = "● codex ✓"
	StagePRReady   = "● pr-ready"
	StageQuick     = "● quick"
	StageActive    = "● active"
	StageStopped   = "○ stopped"
	StageError     = "⚠ error"
)

type evidenceVerdict struct{ hasAny, approved bool }

// DeriveWorkflowStage reads the evidence JSONL for sessionID and returns
// the highest workflow stage reached at the latest diff hash.
func DeriveWorkflowStage(sessionID string) string {
	entries := readAllEvidence(sessionID)
	if len(entries) == 0 {
		return StageActive
	}

	var latestHash string
	for i := len(entries) - 1; i >= 0; i-- {
		if entries[i].DiffHash != "" {
			latestHash = entries[i].DiffHash
			break
		}
	}
	if latestHash == "" {
		return StageActive
	}

	seen := make(map[string]*evidenceVerdict)
	for _, e := range entries {
		if e.DiffHash != latestHash {
			continue
		}
		v, ok := seen[e.Type]
		if !ok {
			v = &evidenceVerdict{}
			seen[e.Type] = v
		}
		v.hasAny = true
		if e.Result == "APPROVED" {
			v.approved = true
		}
	}

	if has(seen, "pr-verified") {
		return StagePRReady
	}
	if has(seen, "quick-tier") {
		return StageQuick
	}
	if v, ok := seen["codex"]; ok {
		if v.approved {
			return StageCodexOK
		}
		return StageCodex
	}
	criticOK := approved(seen, "code-critic") && approved(seen, "minimizer") && (!has(seen, "scribe") || approved(seen, "scribe"))
	if has(seen, "code-critic") || has(seen, "minimizer") || has(seen, "scribe") {
		if criticOK {
			return StageCriticsOK
		}
		return StageCritics
	}
	if has(seen, "check-runner") && has(seen, "test-runner") {
		return StageChecks
	}
	if has(seen, "test-runner") {
		return StageTesting
	}
	if has(seen, "check-runner") {
		return StageChecks
	}

	return StageActive
}

func has(m map[string]*evidenceVerdict, key string) bool {
	v, ok := m[key]
	return ok && v.hasAny
}

func approved(m map[string]*evidenceVerdict, key string) bool {
	v, ok := m[key]
	return ok && v.approved
}

// readAllEvidence reads every entry from the evidence JSONL (no limit).
func readAllEvidence(sessionID string) []EvidenceEntry {
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
	return entries
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

	if len(entries) > maxEntries {
		entries = entries[len(entries)-maxEntries:]
	}
	return entries
}
