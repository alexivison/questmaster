package picker

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/anthropics/ai-config/tools/party-cli/internal/state"
	"github.com/anthropics/ai-config/tools/party-cli/internal/tmux"
)

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

func writeManifest(t *testing.T, root string, m state.Manifest) {
	t.Helper()
	data, err := json.Marshal(m)
	if err != nil {
		t.Fatalf("marshal manifest: %v", err)
	}
	if err := os.WriteFile(filepath.Join(root, m.PartyID+".json"), data, 0o644); err != nil {
		t.Fatalf("write manifest: %v", err)
	}
}

type mockRunner struct {
	fn func(ctx context.Context, args ...string) (string, error)
}

func (m *mockRunner) Run(ctx context.Context, args ...string) (string, error) {
	return m.fn(ctx, args...)
}

// ---------------------------------------------------------------------------
// BuildEntries tests
// ---------------------------------------------------------------------------

func TestBuildEntries_MixedActiveStaleMaster(t *testing.T) {
	t.Parallel()
	root := t.TempDir()

	// Create manifests: standalone active, master with worker, stale session
	writeManifest(t, root, state.Manifest{
		PartyID: "party-standalone", Title: "standalone", Cwd: "/tmp/a",
	})
	writeManifest(t, root, state.Manifest{
		PartyID: "party-master", Title: "master-sess", Cwd: "/tmp/b",
		SessionType: "master", Workers: []string{"party-worker"},
	})
	writeManifest(t, root, state.Manifest{
		PartyID: "party-worker", Title: "worker-sess", Cwd: "/tmp/c",
		Extra: map[string]json.RawMessage{"parent_session": json.RawMessage(`"party-master"`)},
	})
	writeManifest(t, root, state.Manifest{
		PartyID: "party-stale", Title: "stale-sess", Cwd: "/tmp/d",
		CreatedAt: "2026-03-01T00:00:00Z",
	})

	store := state.OpenStore(root)

	// Mock tmux: party-standalone, party-master, party-worker are live
	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) > 0 && args[0] == "list-sessions" {
			return "party-standalone\nparty-master\nparty-worker\nnon-party-sess", nil
		}
		if len(args) > 0 && args[0] == "display-message" {
			return "party-standalone", nil // current session
		}
		return "", nil
	}}
	client := tmux.NewClient(runner)

	entries, err := BuildEntries(t.Context(), store, client)
	if err != nil {
		t.Fatalf("BuildEntries: %v", err)
	}

	// Expect: standalone (current), master, worker (indented), separator, stale
	if len(entries) < 4 {
		t.Fatalf("expected at least 4 entries, got %d: %+v", len(entries), entries)
	}

	// Standalone should be marked current
	found := false
	for _, e := range entries {
		if e.SessionID == "party-standalone" && e.Status == "* current" {
			found = true
			break
		}
	}
	if !found {
		t.Error("standalone should be marked as current session")
	}

	// Master entry should include worker count
	for _, e := range entries {
		if e.SessionID == "party-master" {
			if e.Status != "master (1)" {
				t.Errorf("master status: got %q, want %q", e.Status, "master (1)")
			}
			break
		}
	}

	// Worker entry should be indented (hierarchical display parity with shell picker)
	hasIndentedWorker := false
	for _, e := range entries {
		if e.SessionID == "  party-worker" {
			hasIndentedWorker = true
			break
		}
	}
	if !hasIndentedWorker {
		t.Error("worker session ID should be indented with two leading spaces")
	}

	// Stale entry should exist
	hasStale := false
	for _, e := range entries {
		if e.SessionID == "party-stale" {
			hasStale = true
			if e.Title != "stale-sess" {
				t.Errorf("stale title: got %q, want %q", e.Title, "stale-sess")
			}
		}
	}
	if !hasStale {
		t.Error("expected stale session in entries")
	}
}

func TestBuildEntries_NoSessions(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	store := state.OpenStore(root)

	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) > 0 && args[0] == "list-sessions" {
			return "", &tmux.ExitError{Code: 1}
		}
		return "", nil
	}}
	client := tmux.NewClient(runner)

	entries, err := BuildEntries(t.Context(), store, client)
	if err != nil {
		t.Fatalf("BuildEntries: %v", err)
	}
	if len(entries) != 0 {
		t.Errorf("expected 0 entries, got %d", len(entries))
	}
}

func TestBuildEntries_OrphanWorker(t *testing.T) {
	t.Parallel()
	root := t.TempDir()

	writeManifest(t, root, state.Manifest{
		PartyID: "party-orphan", Title: "orphan", Cwd: "/tmp/o",
		Extra: map[string]json.RawMessage{"parent_session": json.RawMessage(`"party-dead-master"`)},
	})

	store := state.OpenStore(root)
	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) > 0 && args[0] == "list-sessions" {
			return "party-orphan", nil
		}
		return "", nil
	}}
	client := tmux.NewClient(runner)

	entries, err := BuildEntries(t.Context(), store, client)
	if err != nil {
		t.Fatalf("BuildEntries: %v", err)
	}

	found := false
	for _, e := range entries {
		if e.SessionID == "party-orphan" && e.Status == "worker (orphan)" {
			found = true
		}
	}
	if !found {
		t.Error("expected orphan worker entry with 'worker (orphan)' status")
	}
}

// ---------------------------------------------------------------------------
// BuildPreview tests
// ---------------------------------------------------------------------------

func TestBuildPreview_ActiveSession(t *testing.T) {
	t.Parallel()
	root := t.TempDir()

	writeManifest(t, root, state.Manifest{
		PartyID:   "party-active",
		Title:     "active-sess",
		Cwd:       "/tmp/a",
		CreatedAt: "2026-03-10T12:00:00Z",
		Extra: map[string]json.RawMessage{
			"initial_prompt":    json.RawMessage(`"fix the bug"`),
			"claude_session_id": json.RawMessage(`"claude-123"`),
			"codex_thread_id":   json.RawMessage(`"codex-456"`),
		},
	})

	store := state.OpenStore(root)
	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) > 0 && args[0] == "has-session" {
			return "", nil // session exists
		}
		// list-panes for role resolution: "window_index pane_index @party_role"
		if len(args) > 0 && args[0] == "list-panes" {
			return "1 0 claude", nil
		}
		// capture-pane
		if len(args) > 0 && args[0] == "capture-pane" {
			return "❯ git status\n⏺ Running git status...\n❯ make test", nil
		}
		return "", nil
	}}
	client := tmux.NewClient(runner)

	preview, err := BuildPreview(t.Context(), "party-active", store, client)
	if err != nil {
		t.Fatalf("BuildPreview: %v", err)
	}
	if preview == nil {
		t.Fatal("expected non-nil preview")
	}
	if preview.Status != "active" {
		t.Errorf("status: got %q, want %q", preview.Status, "active")
	}
	if preview.Prompt != "fix the bug" {
		t.Errorf("prompt: got %q, want %q", preview.Prompt, "fix the bug")
	}
	if preview.ClaudeID != "claude-123" {
		t.Errorf("claude ID: got %q, want %q", preview.ClaudeID, "claude-123")
	}
}

func TestBuildPreview_MasterSession(t *testing.T) {
	t.Parallel()
	root := t.TempDir()

	writeManifest(t, root, state.Manifest{
		PartyID:     "party-master",
		SessionType: "master",
		Workers:     []string{"w1", "w2", "w3"},
		Cwd:         "/tmp/m",
		CreatedAt:   "2026-03-10T12:00:00Z",
	})

	store := state.OpenStore(root)
	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) > 0 && args[0] == "has-session" {
			return "", nil
		}
		return "", &tmux.ExitError{Code: 1}
	}}
	client := tmux.NewClient(runner)

	preview, err := BuildPreview(t.Context(), "party-master", store, client)
	if err != nil {
		t.Fatalf("BuildPreview: %v", err)
	}
	if preview.Status != "master" {
		t.Errorf("status: got %q, want %q", preview.Status, "master")
	}
	if preview.WorkerCount != 3 {
		t.Errorf("worker count: got %d, want 3", preview.WorkerCount)
	}
}

func TestBuildPreview_ResumableSession(t *testing.T) {
	t.Parallel()
	root := t.TempDir()

	writeManifest(t, root, state.Manifest{
		PartyID:   "party-stale",
		Title:     "old-sess",
		Cwd:       "/tmp/s",
		CreatedAt: "2026-03-01T00:00:00Z",
		Extra: map[string]json.RawMessage{
			"last_started_at": json.RawMessage(`"2026-03-05T10:00:00Z"`),
		},
	})

	store := state.OpenStore(root)
	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		return "", &tmux.ExitError{Code: 1}
	}}
	client := tmux.NewClient(runner)

	preview, err := BuildPreview(t.Context(), "party-stale", store, client)
	if err != nil {
		t.Fatalf("BuildPreview: %v", err)
	}
	if preview.Status != "resumable" {
		t.Errorf("status: got %q, want %q", preview.Status, "resumable")
	}
	if preview.Timestamp != "2026-03-05T10:00:00Z" {
		t.Errorf("timestamp: got %q, want last_started_at", preview.Timestamp)
	}
	if len(preview.PaneLines) != 0 {
		t.Errorf("stale session should have no pane lines, got %d", len(preview.PaneLines))
	}
}

func TestBuildPreview_NoManifest(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	store := state.OpenStore(root)

	runner := &mockRunner{fn: func(_ context.Context, _ ...string) (string, error) {
		return "", &tmux.ExitError{Code: 1}
	}}
	client := tmux.NewClient(runner)

	preview, err := BuildPreview(t.Context(), "party-nonexistent", store, client)
	if err != nil {
		t.Fatalf("BuildPreview: %v", err)
	}
	if preview != nil {
		t.Error("expected nil preview for missing manifest")
	}
}

// ---------------------------------------------------------------------------
// filterPaneLines tests
// ---------------------------------------------------------------------------

func TestFilterPaneLines_FiltersAndCaps(t *testing.T) {
	t.Parallel()

	raw := "some random line\n❯ git status\n⏺ Running...\n❯\n⏺\nplain text\n❯ make test\n⏺ All passed\n❯ exit"
	got := tmux.FilterAgentLines(raw, 3)

	// Should exclude non-prefixed lines, blank ❯/⏺ lines, and cap at 3.
	if len(got) != 3 {
		t.Fatalf("expected 3 lines, got %d: %v", len(got), got)
	}
	// Should be the last 3 significant lines.
	if got[0] != "❯ make test" {
		t.Errorf("line 0: got %q, want %q", got[0], "❯ make test")
	}
	if got[1] != "⏺ All passed" {
		t.Errorf("line 1: got %q, want %q", got[1], "⏺ All passed")
	}
	if got[2] != "❯ exit" {
		t.Errorf("line 2: got %q, want %q", got[2], "❯ exit")
	}
}

func TestFilterPaneLines_Empty(t *testing.T) {
	t.Parallel()
	got := tmux.FilterAgentLines("", 8)
	if len(got) != 0 {
		t.Errorf("expected 0 lines for empty input, got %d", len(got))
	}
}

func TestFilterPaneLines_AllBlankPrefixes(t *testing.T) {
	t.Parallel()
	got := tmux.FilterAgentLines("❯\n⏺\n❯  \n⏺  ", 8)
	if len(got) != 0 {
		t.Errorf("expected 0 lines for blank-prefix-only input, got %d", len(got))
	}
}

// ---------------------------------------------------------------------------
// FormatEntries ANSI token tests
// ---------------------------------------------------------------------------

func TestFormatEntries_ColumnSeparatorsUseMutedANSI(t *testing.T) {
	t.Parallel()
	entries := []Entry{
		{SessionID: "party-test", Status: "active", Title: "test", Cwd: "/tmp"},
	}
	got := FormatEntries(entries)

	// Column separators must use ANSI 8 (bright black): \033[90m
	mutedANSI := "\033[90m"
	if !strings.Contains(got, mutedANSI+" | "+"\033[0m") {
		t.Errorf("FormatEntries column separator should use Muted ANSI 8 (\\033[90m), got:\n%s", got)
	}

	// Must NOT contain any RGB escape sequences.
	if strings.Contains(got, "\033[38;2;") {
		t.Error("FormatEntries must not contain hardcoded RGB ANSI escape sequences")
	}
}

func TestFormatEntries_ResumableDividerUsesDividerANSI(t *testing.T) {
	t.Parallel()
	entries := []Entry{
		{SessionID: "party-active", Status: "active", Title: "a", Cwd: "/tmp"},
		{IsSep: true},
		{SessionID: "party-stale", Status: "03/01", Title: "b", Cwd: "/tmp"},
	}
	got := FormatEntries(entries)

	// Resumable divider must use DividerFg ANSI 240: \033[38;5;240m
	dividerANSI := "\033[38;5;240m"
	if !strings.Contains(got, dividerANSI) {
		t.Errorf("FormatEntries resumable divider should use DividerFg ANSI 240 (\\033[38;5;240m), got:\n%s", got)
	}
}

// ---------------------------------------------------------------------------
// FormatPreview ANSI token tests
// ---------------------------------------------------------------------------

func TestFormatPreview_MasterUsesAccentANSI(t *testing.T) {
	t.Parallel()
	pd := &PreviewData{Status: "master", WorkerCount: 2, Cwd: "/tmp", Timestamp: "2026-03-10"}
	got := FormatPreview(pd)

	accentANSI := "\033[34m"
	if !strings.Contains(got, accentANSI+"master") {
		t.Errorf("FormatPreview master status should use Accent ANSI 4 (\\033[34m), got:\n%s", got)
	}

	if strings.Contains(got, "\033[38;2;") {
		t.Error("FormatPreview must not contain hardcoded RGB ANSI escape sequences")
	}
}

func TestFormatPreview_ActiveUsesCleanANSI(t *testing.T) {
	t.Parallel()
	pd := &PreviewData{Status: "active", Cwd: "/tmp", Timestamp: "2026-03-10", Prompt: "fix bug"}
	got := FormatPreview(pd)

	cleanANSI := "\033[32m"
	if !strings.Contains(got, cleanANSI+"active") {
		t.Errorf("FormatPreview active status should use Clean ANSI 2 (\\033[32m), got:\n%s", got)
	}
	if !strings.Contains(got, cleanANSI+"prompt: fix bug") {
		t.Errorf("FormatPreview prompt should use Clean ANSI 2, got:\n%s", got)
	}
}

func TestFormatPreview_ResumableUsesMutedANSI(t *testing.T) {
	t.Parallel()
	pd := &PreviewData{
		Status:    "resumable",
		Cwd:       "/tmp/project",
		Timestamp: "2026-03-05T10:00:00Z",
		ClaudeID:  "claude-abc",
		CodexID:   "codex-xyz",
	}
	got := FormatPreview(pd)

	mutedANSI := "\033[90m"
	if !strings.Contains(got, mutedANSI+"resumable") {
		t.Errorf("FormatPreview resumable status should use Muted ANSI 8, got:\n%s", got)
	}
	if !strings.Contains(got, mutedANSI+"/tmp/project") {
		t.Errorf("FormatPreview cwd should use Muted ANSI 8, got:\n%s", got)
	}
	if !strings.Contains(got, mutedANSI+"2026-03-05T10:00:00Z") {
		t.Errorf("FormatPreview timestamp should use Muted ANSI 8, got:\n%s", got)
	}
	if !strings.Contains(got, mutedANSI+"claude: claude-abc") {
		t.Errorf("FormatPreview claude ID should use Muted ANSI 8, got:\n%s", got)
	}
	if !strings.Contains(got, mutedANSI+"wizard: codex-xyz") {
		t.Errorf("FormatPreview wizard ID should use Muted ANSI 8, got:\n%s", got)
	}
}

func TestFormatPreview_PaladinHeaderUsesAccentANSI(t *testing.T) {
	t.Parallel()
	pd := &PreviewData{
		Status:    "active",
		Cwd:       "/tmp",
		Timestamp: "2026-03-10",
		PaneLines: []string{"❯ git status", "some output"},
	}
	got := FormatPreview(pd)

	accentANSI := "\033[34m"
	if !strings.Contains(got, accentANSI+"--- Paladin ---") {
		t.Errorf("FormatPreview Paladin header should use Accent ANSI 4, got:\n%s", got)
	}
}

func TestFormatPreview_PromptLinesUseCleanANSI(t *testing.T) {
	t.Parallel()
	pd := &PreviewData{
		Status:    "active",
		Cwd:       "/tmp",
		Timestamp: "2026-03-10",
		PaneLines: []string{"❯ git status"},
	}
	got := FormatPreview(pd)

	cleanANSI := "\033[32m"
	if !strings.Contains(got, cleanANSI+"❯ git status") {
		t.Errorf("FormatPreview prompt (❯) lines should use Clean ANSI 2, got:\n%s", got)
	}
}
