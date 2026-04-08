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

// ---------------------------------------------------------------------------
// CodexStatus parsing
// ---------------------------------------------------------------------------

func TestParseCodexStatus_Working(t *testing.T) {
	t.Parallel()

	raw := `{"state":"working","target":"main","mode":"review","started_at":"2026-03-22T10:00:00Z"}`
	cs, err := ParseCodexStatus([]byte(raw))
	if err != nil {
		t.Fatalf("ParseCodexStatus: %v", err)
	}
	if cs.State != CodexWorking {
		t.Errorf("State: got %q, want %q", cs.State, CodexWorking)
	}
	if cs.Target != "main" {
		t.Errorf("Target: got %q, want %q", cs.Target, "main")
	}
	if cs.Mode != "review" {
		t.Errorf("Mode: got %q, want %q", cs.Mode, "review")
	}
	if cs.StartedAt != "2026-03-22T10:00:00Z" {
		t.Errorf("StartedAt: got %q", cs.StartedAt)
	}
}

func TestParseCodexStatus_Idle(t *testing.T) {
	t.Parallel()

	raw := `{"state":"idle","verdict":"APPROVE","finished_at":"2026-03-22T10:05:00Z"}`
	cs, err := ParseCodexStatus([]byte(raw))
	if err != nil {
		t.Fatalf("ParseCodexStatus: %v", err)
	}
	if cs.State != CodexIdle {
		t.Errorf("State: got %q, want %q", cs.State, CodexIdle)
	}
	if cs.Verdict != "APPROVE" {
		t.Errorf("Verdict: got %q, want %q", cs.Verdict, "APPROVE")
	}
}

func TestParseCodexStatus_Error(t *testing.T) {
	t.Parallel()

	raw := `{"state":"error","error":"transport timeout","finished_at":"2026-03-22T10:05:00Z"}`
	cs, err := ParseCodexStatus([]byte(raw))
	if err != nil {
		t.Fatalf("ParseCodexStatus: %v", err)
	}
	if cs.State != CodexError {
		t.Errorf("State: got %q, want %q", cs.State, CodexError)
	}
	if cs.Error != "transport timeout" {
		t.Errorf("Error: got %q", cs.Error)
	}
}

func TestParseCodexStatus_InvalidJSON(t *testing.T) {
	t.Parallel()

	_, err := ParseCodexStatus([]byte(`{broken`))
	if err == nil {
		t.Fatal("expected error for invalid JSON, got nil")
	}
}

func TestParseCodexStatus_UnknownState(t *testing.T) {
	t.Parallel()

	raw := `{"state":"bogus"}`
	cs, err := ParseCodexStatus([]byte(raw))
	if err != nil {
		t.Fatalf("ParseCodexStatus: %v", err)
	}
	// Unknown state should parse but not match known constants
	if cs.State == CodexWorking || cs.State == CodexIdle || cs.State == CodexError {
		t.Errorf("expected unknown state, got %q", cs.State)
	}
}

// ---------------------------------------------------------------------------
// ReadCodexStatus from file
// ---------------------------------------------------------------------------

func TestReadCodexStatus_FromFile(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	now := time.Now().UTC().Format(time.RFC3339)
	data := fmt.Sprintf(`{"state":"working","target":"review.md","mode":"review","started_at":"%s"}`, now)
	if err := os.WriteFile(filepath.Join(dir, "codex-status.json"), []byte(data), 0644); err != nil {
		t.Fatal(err)
	}

	cs, err := ReadCodexStatus(dir)
	if err != nil {
		t.Fatalf("ReadCodexStatus: %v", err)
	}
	if cs.State != CodexWorking {
		t.Errorf("State: got %q, want %q", cs.State, CodexWorking)
	}
	if cs.Target != "review.md" {
		t.Errorf("Target: got %q", cs.Target)
	}
}

func TestReadCodexStatus_MissingFile(t *testing.T) {
	t.Parallel()

	cs, err := ReadCodexStatus(t.TempDir())
	if err != nil {
		t.Fatalf("expected nil error for missing file, got: %v", err)
	}
	if cs.State != CodexOffline {
		t.Errorf("State: got %q, want %q", cs.State, CodexOffline)
	}
}

func TestReadCodexStatus_EmptyFile(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "codex-status.json"), []byte(""), 0644); err != nil {
		t.Fatal(err)
	}

	cs, err := ReadCodexStatus(dir)
	if err != nil {
		t.Fatalf("expected nil error for empty file, got: %v", err)
	}
	if cs.State != CodexOffline {
		t.Errorf("State: got %q, want %q", cs.State, CodexOffline)
	}
}

func TestReadCodexStatus_StaleFile(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	// "working" state with a started_at far in the past (> stale threshold)
	data := `{"state":"working","target":"old","mode":"prompt","started_at":"2020-01-01T00:00:00Z"}`
	if err := os.WriteFile(filepath.Join(dir, "codex-status.json"), []byte(data), 0644); err != nil {
		t.Fatal(err)
	}

	cs, err := ReadCodexStatus(dir)
	if err != nil {
		t.Fatalf("ReadCodexStatus: %v", err)
	}
	// Stale working state should be treated as error/stale
	if cs.State != CodexError {
		t.Errorf("State: got %q, want %q for stale working status", cs.State, CodexError)
	}
}

// ---------------------------------------------------------------------------
// Sidebar rendering
// ---------------------------------------------------------------------------

func TestRenderSidebar_Working_FlatListLayout(t *testing.T) {
	t.Parallel()

	cs := CodexStatus{
		State:     CodexWorking,
		Target:    "main",
		Mode:      "review",
		StartedAt: time.Now().UTC().Format(time.RFC3339),
	}
	out := RenderSidebar(cs, 60)

	// "Wizard" must appear as a section header, not a "Codex: working" label:value pair
	if !strings.Contains(out, "Wizard") {
		t.Errorf("expected 'Wizard' section header in output, got:\n%s", out)
	}
	// Working state indicator must be present
	if !strings.Contains(out, "working") {
		t.Errorf("expected 'working' state indicator, got:\n%s", out)
	}
	// Detail line must use · separators for compacted mode/target/elapsed
	if !strings.Contains(out, "·") {
		t.Errorf("expected '·' separator in indented detail line, got:\n%s", out)
	}
	// Must NOT use old "mode:" or "target:" label:value format
	if strings.Contains(out, "mode:") || strings.Contains(out, "target:") || strings.Contains(out, "elapsed:") {
		t.Error("flat-list layout must not use label:value format for mode/target/elapsed")
	}
}

func TestRenderSidebar_Idle_FlatListLayout(t *testing.T) {
	t.Parallel()

	cs := CodexStatus{
		State:      CodexIdle,
		Verdict:    "APPROVE",
		FinishedAt: "2026-03-22T10:05:00Z",
	}
	out := RenderSidebar(cs, 60)

	if !strings.Contains(out, "Wizard") {
		t.Errorf("expected 'Wizard' section header, got:\n%s", out)
	}
	if !strings.Contains(out, "idle") {
		t.Errorf("expected 'idle' state indicator, got:\n%s", out)
	}
	if !strings.Contains(out, "APPROVE") {
		t.Errorf("expected 'APPROVE' in output, got:\n%s", out)
	}
	// Must NOT use old "verdict:" label:value format
	if strings.Contains(out, "verdict:") || strings.Contains(out, "finished:") {
		t.Error("flat-list layout must not use label:value format for verdict/finished")
	}
}

func TestRenderSidebar_Error_Readable(t *testing.T) {
	t.Parallel()

	cs := CodexStatus{
		State: CodexError,
		Error: "transport timeout",
	}
	out := RenderSidebar(cs, 60)
	if !strings.Contains(out, "Wizard") {
		t.Errorf("expected 'Wizard' section header, got:\n%s", out)
	}
	if !strings.Contains(out, "error") {
		t.Errorf("expected error indication, got:\n%s", out)
	}
	if !strings.Contains(out, "transport timeout") {
		t.Errorf("expected error message in output, got:\n%s", out)
	}
}

func TestRenderSidebar_Offline_Readable(t *testing.T) {
	t.Parallel()

	cs := CodexStatus{State: CodexOffline}
	out := RenderSidebar(cs, 60)
	if !strings.Contains(out, "Wizard") {
		t.Errorf("expected 'Wizard' section header, got:\n%s", out)
	}
	if !strings.Contains(out, "offline") {
		t.Errorf("expected offline indication, got:\n%s", out)
	}
}

func TestRenderSidebar_CompactWidth(t *testing.T) {
	t.Parallel()

	cs := CodexStatus{
		State:  CodexWorking,
		Target: "some-very-long-description-that-should-be-truncated",
		Mode:   "review",
	}
	out := RenderSidebar(cs, 30)
	if out == "" {
		t.Error("expected non-empty output for compact width")
	}
}

func TestRenderSidebar_ZeroWidth(t *testing.T) {
	t.Parallel()

	cs := CodexStatus{State: CodexIdle}
	out := RenderSidebar(cs, 0)
	if out == "" {
		t.Error("expected non-empty output for zero width")
	}
}

func TestRenderSidebar_HeaderLinesNoGutter(t *testing.T) {
	t.Parallel()

	cs := CodexStatus{State: CodexIdle, Verdict: "APPROVE"}
	out := RenderSidebar(cs, 60)

	// The "Wizard" section header must not be indented — only detail lines get "  " indent.
	for _, line := range strings.Split(out, "\n") {
		if line == "" {
			continue
		}
		stripped := stripANSI(line)
		if strings.HasPrefix(stripped, "Wizard") {
			// Header must NOT have a leading gutter
			if strings.HasPrefix(line, "  ") {
				t.Errorf("section header must not have hard-coded gutter; found: %q", line)
			}
		}
	}
}

// stripANSI removes ANSI escape sequences for plain-text assertions.
func stripANSI(s string) string {
	var out strings.Builder
	i := 0
	for i < len(s) {
		if s[i] == '\033' && i+1 < len(s) && s[i+1] == '[' {
			j := i + 2
			for j < len(s) && !((s[j] >= 'A' && s[j] <= 'Z') || (s[j] >= 'a' && s[j] <= 'z')) {
				j++
			}
			if j < len(s) {
				j++
			}
			i = j
			continue
		}
		out.WriteByte(s[i])
		i++
	}
	return out.String()
}

// ---------------------------------------------------------------------------
// CodexStatus JSON round-trip
// ---------------------------------------------------------------------------

func TestCodexStatus_RoundTrip(t *testing.T) {
	t.Parallel()

	original := CodexStatus{
		State:      CodexIdle,
		Target:     "main",
		Mode:       "review",
		Verdict:    "APPROVE",
		StartedAt:  "2026-03-22T10:00:00Z",
		FinishedAt: "2026-03-22T10:05:00Z",
	}

	data, err := json.Marshal(original)
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}

	parsed, err := ParseCodexStatus(data)
	if err != nil {
		t.Fatalf("ParseCodexStatus: %v", err)
	}
	if parsed.State != original.State {
		t.Errorf("State: got %q, want %q", parsed.State, original.State)
	}
	if parsed.Verdict != original.Verdict {
		t.Errorf("Verdict: got %q, want %q", parsed.Verdict, original.Verdict)
	}
}

// ---------------------------------------------------------------------------
// Evidence summary
// ---------------------------------------------------------------------------

func TestReadEvidenceSummary_MissingFile(t *testing.T) {
	t.Parallel()

	entries := ReadEvidenceSummary("nonexistent-session-"+t.Name(), 5)
	if len(entries) != 0 {
		t.Errorf("expected empty entries, got %d", len(entries))
	}
}

func TestReadEvidenceSummary_ParsesEntries(t *testing.T) {
	t.Parallel()

	sessionID := fmt.Sprintf("test-evidence-parse-%d", time.Now().UnixNano())

	lines := `{"timestamp":"2026-03-22T10:00:00Z","type":"code-critic","result":"APPROVED","diff_hash":"abc123"}
{"timestamp":"2026-03-22T10:01:00Z","type":"minimizer","result":"REQUEST_CHANGES","diff_hash":"abc123"}
{"timestamp":"2026-03-22T10:02:00Z","type":"codex","result":"APPROVED","diff_hash":"def456"}
`
	tmpPath := fmt.Sprintf("/tmp/claude-evidence-%s.jsonl", sessionID)
	if err := os.WriteFile(tmpPath, []byte(lines), 0644); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Remove(tmpPath) })

	entries := ReadEvidenceSummary(sessionID, 5)
	if len(entries) != 3 {
		t.Fatalf("expected 3 entries, got %d", len(entries))
	}
	if entries[0].Type != "code-critic" {
		t.Errorf("first entry type: got %q", entries[0].Type)
	}
	if entries[1].Result != "REQUEST_CHANGES" {
		t.Errorf("second entry result: got %q", entries[1].Result)
	}
}

func TestReadEvidenceSummary_LimitsEntries(t *testing.T) {
	t.Parallel()

	sessionID := fmt.Sprintf("test-evidence-limit-%d", time.Now().UnixNano())
	tmpPath := fmt.Sprintf("/tmp/claude-evidence-%s.jsonl", sessionID)

	var lines string
	for i := 0; i < 10; i++ {
		lines += fmt.Sprintf(`{"timestamp":"2026-03-22T10:%02d:00Z","type":"critic-%d","result":"APPROVED","diff_hash":"h%d"}`, i, i, i) + "\n"
	}
	if err := os.WriteFile(tmpPath, []byte(lines), 0644); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Remove(tmpPath) })

	entries := ReadEvidenceSummary(sessionID, 3)
	if len(entries) != 3 {
		t.Fatalf("expected 3 entries, got %d", len(entries))
	}
	if entries[0].Type != "critic-7" {
		t.Errorf("first entry type: got %q, want critic-7", entries[0].Type)
	}
}

func TestRenderEvidence_Empty(t *testing.T) {
	t.Parallel()

	out := RenderEvidence(nil, 60)
	if out != "" {
		t.Errorf("expected empty string for empty evidence, got %q", out)
	}
}

func TestRenderEvidence_IndentedSubList(t *testing.T) {
	t.Parallel()

	entries := []EvidenceEntry{
		{Type: "code-critic", Result: "APPROVED"},
		{Type: "codex", Result: "REQUEST_CHANGES"},
	}
	out := RenderEvidence(entries, 60)

	// "Evidence" must appear as a section header
	if !strings.Contains(out, "Evidence") {
		t.Errorf("expected 'Evidence' section header, got:\n%s", out)
	}
	// Entries must be present
	if !strings.Contains(out, "code-critic") {
		t.Errorf("expected 'code-critic' in output, got:\n%s", out)
	}
	if !strings.Contains(out, "REQUEST_CHANGES") {
		t.Errorf("expected 'REQUEST_CHANGES' in output, got:\n%s", out)
	}
	// Evidence entries must NOT use old "  type: result" label:value format
	if strings.Contains(out, "  code-critic: APPROVED") {
		t.Error("evidence must use indented sub-list format, not 'type: result' label:value")
	}
}

func TestLatestPerBaseType_DeduplicatesSuffixes(t *testing.T) {
	t.Parallel()

	entries := []EvidenceEntry{
		{Type: "code-critic", Result: "REQUEST_CHANGES", DiffHash: "aaa"},
		{Type: "minimizer-fp", Result: "APPROVED", DiffHash: "aaa"},
		{Type: "code-critic-run", Result: "APPROVED", DiffHash: "bbb"},
		{Type: "test-runner", Result: "PASS", DiffHash: "bbb"},
	}

	got := latestPerBaseType(entries)

	// Should collapse to 3 base types: code-critic, minimizer, test-runner.
	if len(got) != 3 {
		t.Fatalf("expected 3 entries, got %d: %+v", len(got), got)
	}

	// code-critic: latest is the -run entry with APPROVED.
	if got[0].Type != "code-critic" || got[0].Result != "APPROVED" {
		t.Errorf("code-critic: expected APPROVED, got %+v", got[0])
	}
	// minimizer: -fp suffix stripped, result preserved.
	if got[1].Type != "minimizer" || got[1].Result != "APPROVED" {
		t.Errorf("minimizer: expected APPROVED, got %+v", got[1])
	}
	// test-runner: no suffix, passed through unchanged.
	if got[2].Type != "test-runner" || got[2].Result != "PASS" {
		t.Errorf("test-runner: expected PASS, got %+v", got[2])
	}
}

func TestLatestPerBaseType_PrefersVerdictOverHash(t *testing.T) {
	t.Parallel()

	hash := "01bd48eaba34c5a4ec21bd928ec8f335194da66b37c996240f0a9a38afc0de41"

	// Hash result first, then real verdict — should prefer verdict.
	entries := []EvidenceEntry{
		{Type: "minimizer-fp", Result: hash},
		{Type: "minimizer", Result: "APPROVED"},
	}
	got := latestPerBaseType(entries)
	if len(got) != 1 {
		t.Fatalf("expected 1 entry, got %d", len(got))
	}
	if got[0].Result != "APPROVED" {
		t.Errorf("expected APPROVED over hash, got %q", got[0].Result)
	}

	// Real verdict first, then hash — should keep verdict.
	entries2 := []EvidenceEntry{
		{Type: "minimizer", Result: "REQUEST_CHANGES"},
		{Type: "minimizer-fp", Result: hash},
	}
	got2 := latestPerBaseType(entries2)
	if got2[0].Result != "REQUEST_CHANGES" {
		t.Errorf("expected REQUEST_CHANGES preserved, got %q", got2[0].Result)
	}

	// Hash then hash — later hash wins (no verdict available).
	hash2 := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	entries3 := []EvidenceEntry{
		{Type: "minimizer-fp", Result: hash},
		{Type: "minimizer-fp", Result: hash2},
	}
	got3 := latestPerBaseType(entries3)
	if got3[0].Result != hash2 {
		t.Errorf("expected later hash to win, got %q", got3[0].Result)
	}
}

func TestEvidenceBaseType_Suffixes(t *testing.T) {
	t.Parallel()

	cases := map[string]string{
		"minimizer-fp":    "minimizer",
		"code-critic-run": "code-critic",
		"minimizer-run":   "minimizer",
		"test-runner":     "test-runner",
		"codex":           "codex",
	}
	for input, want := range cases {
		if got := evidenceBaseType(input); got != want {
			t.Errorf("evidenceBaseType(%q) = %q, want %q", input, got, want)
		}
	}
}

func TestRenderEvidence_DeduplicatesInOutput(t *testing.T) {
	t.Parallel()

	entries := []EvidenceEntry{
		{Type: "minimizer", Result: "REQUEST_CHANGES"},
		{Type: "minimizer-fp", Result: "APPROVED"},
	}
	out := RenderEvidence(entries, 60)

	// Should show minimizer only once, with the latest result.
	if count := strings.Count(out, "minimizer"); count != 1 {
		t.Errorf("expected 'minimizer' once, got %d in:\n%s", count, out)
	}
	if !strings.Contains(out, "APPROVED") {
		t.Errorf("expected APPROVED (latest), got:\n%s", out)
	}
}

// ---------------------------------------------------------------------------
// Codex window liveness override
// ---------------------------------------------------------------------------

func TestRefreshCodexStatus_WindowGone_OverridesToOffline(t *testing.T) {
	t.Parallel()

	// Write a valid idle status file
	dir := t.TempDir()
	sessionID := filepath.Base(dir) // use temp dir name as session ID
	// Symlink /tmp/<sessionID> -> dir so ReadCodexStatus finds it
	tmpLink := fmt.Sprintf("/tmp/%s", sessionID)
	if err := os.Symlink(dir, tmpLink); err != nil {
		t.Skipf("cannot create /tmp symlink: %v", err)
	}
	t.Cleanup(func() { os.Remove(tmpLink) })

	data := `{"state":"idle","verdict":"APPROVE","finished_at":"2026-03-22T10:05:00Z"}`
	if err := os.WriteFile(filepath.Join(dir, "codex-status.json"), []byte(data), 0644); err != nil {
		t.Fatal(err)
	}

	// Model with a checker that says window is gone
	m := NewModelWithResolver(stubResolver(sessionID, ViewWorker))
	m.SessionID = sessionID
	m.checkCodexPane = func(_ string) bool { return false }

	cmd := m.refreshCodexStatus()
	if cmd == nil {
		t.Fatal("expected a command")
	}
	msg := cmd()
	csMsg, ok := msg.(codexStatusMsg)
	if !ok {
		t.Fatalf("expected codexStatusMsg, got %T", msg)
	}
	if csMsg.status.State != CodexOffline {
		t.Errorf("expected CodexOffline when window gone, got %q", csMsg.status.State)
	}
}

// ---------------------------------------------------------------------------
// DeriveWorkflowStage
// ---------------------------------------------------------------------------

func writeEvidence(t *testing.T, sessionID string, lines []string) {
	t.Helper()
	path := fmt.Sprintf("/tmp/claude-evidence-%s.jsonl", sessionID)
	if err := os.WriteFile(path, []byte(strings.Join(lines, "\n")+"\n"), 0644); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Remove(path) })
}

func TestDeriveWorkflowStage(t *testing.T) {
	t.Parallel()

	tests := map[string]struct {
		lines []string
		want  string
	}{
		"no file": {
			lines: nil,
			want:  StageActive,
		},
		"empty file": {
			lines: []string{},
			want:  StageActive,
		},
		"test-runner only": {
			lines: []string{
				`{"timestamp":"T","type":"test-runner","result":"PASSED","diff_hash":"aaa"}`,
			},
			want: StageTesting,
		},
		"test-runner + check-runner": {
			lines: []string{
				`{"timestamp":"T","type":"test-runner","result":"PASSED","diff_hash":"aaa"}`,
				`{"timestamp":"T","type":"check-runner","result":"PASSED","diff_hash":"aaa"}`,
			},
			want: StageChecks,
		},
		"check-runner only": {
			lines: []string{
				`{"timestamp":"T","type":"check-runner","result":"PASSED","diff_hash":"aaa"}`,
			},
			want: StageChecks,
		},
		"code-critic present": {
			lines: []string{
				`{"timestamp":"T","type":"test-runner","result":"PASSED","diff_hash":"aaa"}`,
				`{"timestamp":"T","type":"code-critic","result":"REQUEST_CHANGES","diff_hash":"aaa"}`,
			},
			want: StageCritics,
		},
		"minimizer present": {
			lines: []string{
				`{"timestamp":"T","type":"minimizer","result":"REQUEST_CHANGES","diff_hash":"aaa"}`,
			},
			want: StageCritics,
		},
		"both critics approved": {
			lines: []string{
				`{"timestamp":"T","type":"code-critic","result":"APPROVED","diff_hash":"aaa"}`,
				`{"timestamp":"T","type":"minimizer","result":"APPROVED","diff_hash":"aaa"}`,
			},
			want: StageCriticsOK,
		},
		"critic approved but minimizer not": {
			lines: []string{
				`{"timestamp":"T","type":"code-critic","result":"APPROVED","diff_hash":"aaa"}`,
				`{"timestamp":"T","type":"minimizer","result":"REQUEST_CHANGES","diff_hash":"aaa"}`,
			},
			want: StageCritics,
		},
		"codex present": {
			lines: []string{
				`{"timestamp":"T","type":"code-critic","result":"APPROVED","diff_hash":"aaa"}`,
				`{"timestamp":"T","type":"minimizer","result":"APPROVED","diff_hash":"aaa"}`,
				`{"timestamp":"T","type":"codex","result":"REQUEST_CHANGES","diff_hash":"aaa"}`,
			},
			want: StageCodex,
		},
		"codex approved": {
			lines: []string{
				`{"timestamp":"T","type":"codex","result":"APPROVED","diff_hash":"aaa"}`,
			},
			want: StageCodexOK,
		},
		"pr-verified": {
			lines: []string{
				`{"timestamp":"T","type":"codex","result":"APPROVED","diff_hash":"aaa"}`,
				`{"timestamp":"T","type":"pr-verified","result":"PASSED","diff_hash":"aaa"}`,
			},
			want: StagePRReady,
		},
		"quick-tier": {
			lines: []string{
				`{"timestamp":"T","type":"quick-tier","result":"","diff_hash":"aaa"}`,
			},
			want: StageQuick,
		},
		"filters to latest hash": {
			lines: []string{
				`{"timestamp":"T","type":"codex","result":"APPROVED","diff_hash":"old"}`,
				`{"timestamp":"T","type":"test-runner","result":"PASSED","diff_hash":"new"}`,
			},
			want: StageTesting,
		},
		"no diff_hash entries": {
			lines: []string{
				`{"timestamp":"T","type":"test-runner","result":"PASSED","diff_hash":""}`,
			},
			want: StageActive,
		},
		"scribe triggers critics stage": {
			lines: []string{
				`{"timestamp":"T","type":"scribe","result":"APPROVED","diff_hash":"aaa"}`,
			},
			want: StageCritics,
		},
		"scribe blocking prevents critics OK": {
			lines: []string{
				`{"timestamp":"T","type":"code-critic","result":"APPROVED","diff_hash":"aaa"}`,
				`{"timestamp":"T","type":"minimizer","result":"APPROVED","diff_hash":"aaa"}`,
				`{"timestamp":"T","type":"scribe","result":"REQUEST_CHANGES","diff_hash":"aaa"}`,
			},
			want: StageCritics,
		},
	}

	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			sessionID := fmt.Sprintf("test-stage-%s-%d", name, time.Now().UnixNano())
			if tc.lines != nil {
				writeEvidence(t, sessionID, tc.lines)
			}
			got := DeriveWorkflowStage(sessionID)
			if got != tc.want {
				t.Errorf("DeriveWorkflowStage: got %q, want %q", got, tc.want)
			}
		})
	}
}

func TestWorkerRow_StageLabel(t *testing.T) {
	t.Parallel()

	tests := map[string]struct {
		row  WorkerRow
		want string
	}{
		"active with stage": {
			row:  WorkerRow{Status: "active", Stage: StageCritics},
			want: StageCritics,
		},
		"active without stage": {
			row:  WorkerRow{Status: "active"},
			want: StageActive,
		},
		"stopped ignores stage": {
			row:  WorkerRow{Status: "stopped", Stage: StageCodexOK},
			want: StageStopped,
		},
	}

	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			got := tc.row.stageLabel()
			if got != tc.want {
				t.Errorf("stageLabel: got %q, want %q", got, tc.want)
			}
		})
	}
}

func TestRefreshCodexStatus_WindowAlive_KeepsStatus(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	sessionID := filepath.Base(dir)
	tmpLink := fmt.Sprintf("/tmp/%s", sessionID)
	if err := os.Symlink(dir, tmpLink); err != nil {
		t.Skipf("cannot create /tmp symlink: %v", err)
	}
	t.Cleanup(func() { os.Remove(tmpLink) })

	now := time.Now().UTC().Format(time.RFC3339)
	data := fmt.Sprintf(`{"state":"working","target":"main","mode":"review","started_at":"%s"}`, now)
	if err := os.WriteFile(filepath.Join(dir, "codex-status.json"), []byte(data), 0644); err != nil {
		t.Fatal(err)
	}

	m := NewModelWithResolver(stubResolver(sessionID, ViewWorker))
	m.SessionID = sessionID
	m.checkCodexPane = func(_ string) bool { return true }

	cmd := m.refreshCodexStatus()
	msg := cmd()
	csMsg := msg.(codexStatusMsg)
	if csMsg.status.State != CodexWorking {
		t.Errorf("expected CodexWorking when window alive, got %q", csMsg.status.State)
	}
}
