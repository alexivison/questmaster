package tui

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func writeEvidence(t *testing.T, sessionID string, lines []string) {
	t.Helper()
	path := fmt.Sprintf("/tmp/claude-evidence-%s.jsonl", sessionID)
	if err := os.WriteFile(path, []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Remove(path) })
}

func TestParseCompanionStatusWorking(t *testing.T) {
	t.Parallel()

	status, err := ParseCompanionStatus([]byte(`{"state":"working","mode":"review","target":"main"}`))
	if err != nil {
		t.Fatalf("parse companion status: %v", err)
	}
	if status.State != CompanionWorking || status.Mode != "review" || status.Target != "main" {
		t.Fatalf("unexpected parsed status: %#v", status)
	}
}

func TestReadCompanionStatusMissingFile(t *testing.T) {
	t.Parallel()

	status, err := ReadCompanionStatus(t.TempDir(), "codex-status.json")
	if err != nil {
		t.Fatalf("read companion status: %v", err)
	}
	if status.State != CompanionOffline {
		t.Fatalf("expected offline status, got %#v", status)
	}
}

func TestReadCompanionStatusStaleWorkingTurnsError(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "codex-status.json"), []byte(`{"state":"working","started_at":"2020-01-01T00:00:00Z"}`), 0o644); err != nil {
		t.Fatalf("write status: %v", err)
	}

	status, err := ReadCompanionStatus(dir, "codex-status.json")
	if err != nil {
		t.Fatalf("read companion status: %v", err)
	}
	if status.State != CompanionError {
		t.Fatalf("expected stale working to become error, got %#v", status)
	}
}

func TestReadPrimaryStateReadsClaudeStateOnly(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "claude-state.json"), []byte(`{"state":"waiting"}`), 0o644); err != nil {
		t.Fatalf("write primary state: %v", err)
	}
	if got := ReadPrimaryState(dir); got != "waiting" {
		t.Fatalf("expected waiting, got %q", got)
	}
}

func TestRenderCompanionLine(t *testing.T) {
	t.Parallel()

	line := renderCompanionLine("codex", CompanionStatus{State: CompanionIdle, Verdict: "APPROVED"}, 80)
	if !strings.Contains(line, "companion: codex (idle, APPROVED)") {
		t.Fatalf("unexpected companion line: %q", line)
	}
}

func TestRenderEvidenceLine(t *testing.T) {
	t.Parallel()

	line := renderEvidenceLine([]EvidenceEntry{
		{Type: "code-critic", Result: "APPROVED"},
		{Type: "minimizer-fp", Result: "APPROVED"},
	}, 80)
	if !strings.Contains(line, "evidence:") || !strings.Contains(line, "code-critic") || !strings.Contains(line, "minimizer") {
		t.Fatalf("unexpected evidence line: %q", line)
	}
}

func TestCompanionStatusRoundTrip(t *testing.T) {
	t.Parallel()

	original := CompanionStatus{
		State:      CompanionIdle,
		Mode:       "review",
		Verdict:    "APPROVED",
		FinishedAt: time.Now().UTC().Format(time.RFC3339),
	}
	data, err := json.Marshal(original)
	if err != nil {
		t.Fatalf("marshal companion status: %v", err)
	}
	parsed, err := ParseCompanionStatus(data)
	if err != nil {
		t.Fatalf("parse companion status: %v", err)
	}
	if parsed.State != original.State || parsed.Verdict != original.Verdict {
		t.Fatalf("unexpected round trip result: %#v", parsed)
	}
}

func TestReadEvidenceSummaryParsesEntries(t *testing.T) {
	t.Parallel()

	sessionID := fmt.Sprintf("test-evidence-%d", time.Now().UnixNano())
	writeEvidence(t, sessionID, []string{
		`{"timestamp":"T","type":"code-critic","result":"APPROVED","diff_hash":"abc"}`,
		`{"timestamp":"T","type":"minimizer","result":"REQUEST_CHANGES","diff_hash":"abc"}`,
	})

	entries := ReadEvidenceSummary(sessionID, 5)
	if len(entries) != 2 {
		t.Fatalf("expected 2 entries, got %d", len(entries))
	}
}

func TestLatestPerBaseTypeDeduplicatesSuffixes(t *testing.T) {
	t.Parallel()

	got := latestPerBaseType([]EvidenceEntry{
		{Type: "code-critic", Result: "REQUEST_CHANGES"},
		{Type: "code-critic-run", Result: "APPROVED"},
		{Type: "minimizer-fp", Result: "APPROVED"},
	})

	if len(got) != 2 {
		t.Fatalf("expected 2 deduped entries, got %#v", got)
	}
	if got[0].Type != "code-critic" || got[0].Result != "APPROVED" {
		t.Fatalf("expected latest code-critic verdict, got %#v", got[0])
	}
}

func TestDeriveWorkflowStage(t *testing.T) {
	t.Parallel()

	sessionID := fmt.Sprintf("test-stage-%d", time.Now().UnixNano())
	writeEvidence(t, sessionID, []string{
		`{"timestamp":"T","type":"code-critic","result":"APPROVED","diff_hash":"abc"}`,
		`{"timestamp":"T","type":"minimizer","result":"APPROVED","diff_hash":"abc"}`,
	})

	if got := DeriveWorkflowStage(sessionID); got != StageCriticsOK {
		t.Fatalf("expected %q, got %q", StageCriticsOK, got)
	}
}

func TestSessionRowActivityLabelFallsBackToCompanionState(t *testing.T) {
	t.Parallel()

	row := SessionRow{Status: "active", HasCompanion: true, CompanionState: string(CompanionIdle)}
	if got := row.activityLabel(); got != "○ idle" {
		t.Fatalf("expected idle fallback, got %q", got)
	}
}
