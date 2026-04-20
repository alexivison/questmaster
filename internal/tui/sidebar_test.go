package tui

import (
	"fmt"
	"os"
	"strings"
	"testing"
	"time"
)

func writeEvidence(t *testing.T, sessionID string, lines []string) {
	t.Helper()
	path := evidencePath(sessionID)
	if err := os.WriteFile(path, []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Remove(path) })
}

func TestRenderCompanionLine(t *testing.T) {
	t.Parallel()

	line := renderCompanionLine("codex", 120)
	if !strings.Contains(line, "companion: codex") {
		t.Fatalf("unexpected companion line: %q", line)
	}
}

func TestRenderCompanionLineNoAgent(t *testing.T) {
	t.Parallel()

	line := renderCompanionLine("", 120)
	if !strings.Contains(line, "none") {
		t.Fatalf("expected 'none' for empty companion, got %q", line)
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

func TestActivityDotStopped(t *testing.T) {
	t.Parallel()

	row := SessionRow{Status: "stopped"}
	if got := row.activityDot(true); got == "" {
		t.Fatal("expected stopped glyph")
	}
}

func TestIsGeneratingWatchesPrimarySnippetDelta(t *testing.T) {
	t.Parallel()

	cases := []struct {
		name string
		row  SessionRow
		want bool
	}{
		{"primary snippet changed", SessionRow{Status: "active", PrimaryActive: true}, true},
		{"stopped session ignores activity", SessionRow{Status: "stopped", PrimaryActive: true}, false},
		{"unchanged snippet", SessionRow{Status: "active"}, false},
	}
	for _, tc := range cases {
		if got := tc.row.isGenerating(); got != tc.want {
			t.Errorf("%s: isGenerating() = %v, want %v", tc.name, got, tc.want)
		}
	}
}
