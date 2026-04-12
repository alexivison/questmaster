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

// ReadClaudeState reads claude-state.json from a runtime directory.
// Returns empty state (no error) when the file is missing or unreadable.
func ReadClaudeState(runtimeDir string) string {
	path := filepath.Join(runtimeDir, "claude-state.json")
	data, err := os.ReadFile(path)
	if err != nil || len(data) == 0 {
		return ""
	}
	var cs struct {
		State string `json:"state"`
	}
	if json.Unmarshal(data, &cs) != nil {
		return ""
	}
	return cs.State
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
// the highest workflow stage reached at the latest diff_hash.
// Returns StageActive when no evidence is available.
func DeriveWorkflowStage(sessionID string) string {
	entries := readAllEvidence(sessionID)
	if len(entries) == 0 {
		return StageActive
	}

	// Find the latest diff_hash.
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

	// Collect evidence types and results at the latest hash.
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

	// Derive highest stage reached (check from top down).
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

	// Keep only the last maxEntries
	if len(entries) > maxEntries {
		entries = entries[len(entries)-maxEntries:]
	}
	return entries
}
