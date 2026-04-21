package picker

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/muesli/termenv"

	"github.com/anthropics/ai-party/tools/party-cli/internal/palette"
	"github.com/anthropics/ai-party/tools/party-cli/internal/state"
	"github.com/anthropics/ai-party/tools/party-cli/internal/tmux"
	"github.com/anthropics/ai-party/tools/party-cli/internal/tui"
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
		Agents: []state.AgentManifest{{Name: "claude", Role: "primary"}},
	})
	writeManifest(t, root, state.Manifest{
		PartyID: "party-master", Title: "master-sess", Cwd: "/tmp/b",
		SessionType: "master", Workers: []string{"party-worker"},
		Agents: []state.AgentManifest{{Name: "codex", Role: "primary"}},
	})
	writeManifest(t, root, state.Manifest{
		PartyID: "party-worker", Title: "worker-sess", Cwd: "/tmp/c",
		Agents: []state.AgentManifest{{Name: "claude", Role: "primary"}},
		Extra:  map[string]json.RawMessage{"parent_session": json.RawMessage(`"party-master"`)},
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
			if e.PrimaryAgent != "codex" {
				t.Errorf("master primary agent: got %q, want %q", e.PrimaryAgent, "codex")
			}
			break
		}
	}

	// Worker entry should be indented (hierarchical display parity with shell picker)
	hasIndentedWorker := false
	for _, e := range entries {
		if e.SessionID == "  party-worker" {
			hasIndentedWorker = true
			if e.PrimaryAgent != "claude" {
				t.Errorf("worker primary agent: got %q, want %q", e.PrimaryAgent, "claude")
			}
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
			return "1 0 primary", nil
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

func TestBuildPreview_CancelStopsInFlightSubprocess(t *testing.T) {
	t.Parallel()
	root := t.TempDir()

	writeManifest(t, root, state.Manifest{
		PartyID:   "party-active",
		Title:     "active-sess",
		Cwd:       "/tmp/a",
		CreatedAt: "2026-03-10T12:00:00Z",
	})

	store := state.OpenStore(root)
	captureStarted := make(chan struct{})
	runner := &mockRunner{fn: func(ctx context.Context, args ...string) (string, error) {
		switch args[0] {
		case "has-session":
			return "", nil
		case "list-panes":
			return "1 0 primary", nil
		case "capture-pane":
			close(captureStarted)
			<-ctx.Done()
			return "", ctx.Err()
		default:
			return "", nil
		}
	}}
	client := tmux.NewClient(runner)

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		_, err := BuildPreview(ctx, "party-active", store, client)
		done <- err
	}()

	<-captureStarted
	cancel()

	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("expected context cancellation, got %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("BuildPreview did not return after cancellation")
	}
}

func TestModelPreviewDebounce_FiresOnceAfterBurst(t *testing.T) {
	t.Parallel()

	var calls []string
	m := Model{
		active: []Entry{
			{SessionID: "party-a"},
			{SessionID: "party-b"},
			{SessionID: "party-c"},
			{SessionID: "party-d"},
		},
		ctx: context.Background(),
		previewBuild: func(_ context.Context, sessionID string, _ *state.Store, _ *tmux.Client) (*PreviewData, error) {
			calls = append(calls, sessionID)
			return &PreviewData{Status: sessionID}, nil
		},
		previewTimer: func(_ time.Duration, seq int, currentTab tab, currentCursor int) tea.Cmd {
			return func() tea.Msg {
				return previewDebounceMsg{seq: seq, tab: currentTab, cursor: currentCursor}
			}
		},
	}

	var debounceCmds []tea.Cmd
	for i := 0; i < 3; i++ {
		model, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'j'}})
		m = model.(Model)
		debounceCmds = append(debounceCmds, cmd)
	}

	if got := *m.currentCursor(); got != 3 {
		t.Fatalf("cursor after burst: got %d, want 3", got)
	}
	if len(calls) != 0 {
		t.Fatalf("preview should not build before debounce fires, got %d calls", len(calls))
	}

	for _, cmd := range debounceCmds {
		msg := cmd()
		model, next := m.Update(msg)
		m = model.(Model)
		if next == nil {
			continue
		}
		model, _ = m.Update(next())
		m = model.(Model)
	}

	if !reflect.DeepEqual(calls, []string{"party-d"}) {
		t.Fatalf("debounced preview calls = %v, want [party-d]", calls)
	}
	if m.preview == nil || m.preview.Status != "party-d" {
		t.Fatalf("preview = %+v, want final session preview", m.preview)
	}
}

func TestModelPreview_FinalCursorWins(t *testing.T) {
	t.Parallel()

	firstStarted := make(chan struct{})
	firstDone := make(chan tea.Msg, 1)
	var mu sync.Mutex
	var calls []string

	m := Model{
		active: []Entry{
			{SessionID: "party-a"},
			{SessionID: "party-b"},
			{SessionID: "party-c"},
		},
		ctx: context.Background(),
		previewBuild: func(ctx context.Context, sessionID string, _ *state.Store, _ *tmux.Client) (*PreviewData, error) {
			mu.Lock()
			calls = append(calls, sessionID)
			mu.Unlock()

			if sessionID == "party-b" {
				close(firstStarted)
				<-ctx.Done()
				return nil, ctx.Err()
			}
			return &PreviewData{Status: sessionID}, nil
		},
		previewTimer: func(_ time.Duration, seq int, currentTab tab, currentCursor int) tea.Cmd {
			return func() tea.Msg {
				return previewDebounceMsg{seq: seq, tab: currentTab, cursor: currentCursor}
			}
		},
	}

	model, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'j'}})
	m = model.(Model)
	model, next := m.Update(cmd())
	m = model.(Model)
	go func(load tea.Cmd) {
		firstDone <- load()
	}(next)

	<-firstStarted

	model, cmd = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'j'}})
	m = model.(Model)
	model, next = m.Update(cmd())
	m = model.(Model)
	model, _ = m.Update(next())
	m = model.(Model)

	select {
	case staleMsg := <-firstDone:
		model, _ = m.Update(staleMsg)
		m = model.(Model)
	case <-time.After(time.Second):
		t.Fatal("canceled preview did not return")
	}

	mu.Lock()
	gotCalls := append([]string(nil), calls...)
	mu.Unlock()
	if !reflect.DeepEqual(gotCalls, []string{"party-b", "party-c"}) {
		t.Fatalf("preview call order = %v, want [party-b party-c]", gotCalls)
	}
	if got := *m.currentCursor(); got != 2 {
		t.Fatalf("cursor after final move: got %d, want 2", got)
	}
	if m.preview == nil || m.preview.Status != "party-c" {
		t.Fatalf("preview = %+v, want final cursor preview", m.preview)
	}
}

func TestBuildEntries_OrderMatchesTracker(t *testing.T) {
	t.Parallel()
	root := t.TempDir()

	writeManifest(t, root, state.Manifest{
		PartyID:     "party-master-new",
		Title:       "master-new",
		Cwd:         "/tmp/master-new",
		SessionType: "master",
		Workers:     []string{"party-worker-new"},
		CreatedAt:   "2026-03-05T12:00:00Z",
	})
	writeManifest(t, root, state.Manifest{
		PartyID:   "party-worker-new",
		Title:     "worker-new",
		Cwd:       "/tmp/worker-new",
		CreatedAt: "2026-03-04T12:00:00Z",
		Extra: map[string]json.RawMessage{
			"parent_session": json.RawMessage(`"party-master-new"`),
		},
	})
	writeManifest(t, root, state.Manifest{
		PartyID:   "party-standalone",
		Title:     "standalone",
		Cwd:       "/tmp/standalone",
		CreatedAt: "2026-03-03T12:00:00Z",
	})
	writeManifest(t, root, state.Manifest{
		PartyID:     "party-master-old",
		Title:       "master-old",
		Cwd:         "/tmp/master-old",
		SessionType: "master",
		Workers:     []string{"party-worker-old"},
		CreatedAt:   "2026-03-02T12:00:00Z",
	})
	writeManifest(t, root, state.Manifest{
		PartyID:   "party-worker-old",
		Title:     "worker-old",
		Cwd:       "/tmp/worker-old",
		CreatedAt: "2026-03-01T12:00:00Z",
		Extra: map[string]json.RawMessage{
			"parent_session": json.RawMessage(`"party-master-old"`),
		},
	})

	store := state.OpenStore(root)
	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		switch args[0] {
		case "list-sessions":
			return strings.Join([]string{
				"party-worker-old",
				"party-standalone",
				"party-master-new",
				"party-worker-new",
				"party-master-old",
			}, "\n"), nil
		case "display-message", "list-panes":
			return "", nil
		default:
			return "", nil
		}
	}}
	client := tmux.NewClient(runner)

	entries, err := BuildEntries(t.Context(), store, client)
	if err != nil {
		t.Fatalf("BuildEntries: %v", err)
	}

	fetcher := tui.NewLiveSessionFetcher(client, store)
	snapshot, err := fetcher(tui.SessionInfo{})
	if err != nil {
		t.Fatalf("fetch tracker snapshot: %v", err)
	}

	var pickerIDs []string
	for _, entry := range entries {
		if entry.IsSep {
			continue
		}
		pickerIDs = append(pickerIDs, strings.TrimSpace(entry.SessionID))
	}

	var trackerIDs []string
	for _, row := range snapshot.Sessions {
		trackerIDs = append(trackerIDs, row.ID)
	}

	if !reflect.DeepEqual(pickerIDs, trackerIDs) {
		t.Fatalf("picker IDs = %v, want tracker IDs %v", pickerIDs, trackerIDs)
	}
}

// ---------------------------------------------------------------------------
// filterPaneLines tests
// ---------------------------------------------------------------------------

func TestFilterPaneLines_FiltersAndCaps(t *testing.T) {
	t.Parallel()

	raw := "some random line\n❯ git status\n⏺ Running...\n⎿ Done\n❯\n⏺\n⎿\nplain text\n❯ make test\n⏺ All passed\n⎿ Error: exit 1\n   npm error details\n   see log at /tmp/x\n❯ exit"
	got := tmux.FilterAgentLines(raw, 20)

	// Should include ⎿ continuation lines, exclude non-prefixed, blank prefix lines.
	want := []string{
		"⏺ Running...",
		"⎿ Done",
		"⏺ All passed",
		"⎿ Error: exit 1",
		"npm error details",
		"see log at /tmp/x",
	}
	if len(got) != len(want) {
		t.Fatalf("expected %d lines, got %d: %v", len(want), len(got), got)
	}
	for i, w := range want {
		if got[i] != w {
			t.Errorf("line %d: got %q, want %q", i, got[i], w)
		}
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
	got := tmux.FilterAgentLines("❯\n⏺\n⎿\n❯  \n⏺  \n⎿  ", 8)
	if len(got) != 0 {
		t.Errorf("expected 0 lines for blank-prefix-only input, got %d", len(got))
	}
}

// ---------------------------------------------------------------------------
// FormatEntries ANSI token tests
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// BuildTmuxEntries tests
// ---------------------------------------------------------------------------

func TestBuildTmuxEntries_NonPartySessions(t *testing.T) {
	t.Parallel()

	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) > 0 && args[0] == "list-sessions" {
			return "party-abc\t/tmp/a\nmy-dev\t/home/user/code\nscratchy\t/tmp/s", nil
		}
		if len(args) > 0 && args[0] == "display-message" {
			return "my-dev", nil // current session
		}
		return "", nil
	}}
	client := tmux.NewClient(runner)

	entries, err := BuildTmuxEntries(t.Context(), client, "my-dev")
	if err != nil {
		t.Fatalf("BuildTmuxEntries: %v", err)
	}

	// Should only include non-party sessions.
	if len(entries) != 2 {
		t.Fatalf("expected 2 entries, got %d: %+v", len(entries), entries)
	}

	// my-dev should be marked current.
	if entries[0].SessionID != "my-dev" {
		t.Errorf("first entry: got %q, want %q", entries[0].SessionID, "my-dev")
	}
	if !strings.Contains(entries[0].Status, "current") {
		t.Errorf("current session should be marked current, got %q", entries[0].Status)
	}

	// scratchy should be a plain tmux entry.
	if entries[1].SessionID != "scratchy" {
		t.Errorf("second entry: got %q, want %q", entries[1].SessionID, "scratchy")
	}
	if !strings.Contains(entries[1].Status, "tmux") {
		t.Errorf("non-current session should have tmux status, got %q", entries[1].Status)
	}
}

func TestBuildTmuxEntries_NoNonParty(t *testing.T) {
	t.Parallel()

	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) > 0 && args[0] == "list-sessions" {
			return "party-abc\t/tmp/a\nparty-def\t/tmp/b", nil
		}
		return "", nil
	}}
	client := tmux.NewClient(runner)

	entries, err := BuildTmuxEntries(t.Context(), client, "")
	if err != nil {
		t.Fatalf("BuildTmuxEntries: %v", err)
	}
	if len(entries) != 0 {
		t.Errorf("expected 0 entries when all sessions are party-, got %d", len(entries))
	}
}

func TestBuildPreview_TmuxSession(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	store := state.OpenStore(root)

	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) > 0 && args[0] == "has-session" {
			return "", nil // alive
		}
		if len(args) > 0 && args[0] == "display-message" {
			return "/home/user/code", nil
		}
		if len(args) > 0 && args[0] == "capture-pane" {
			return "$ ls\nfile1.txt\nfile2.txt\n$ echo hello\nhello", nil
		}
		return "", nil
	}}
	client := tmux.NewClient(runner)

	preview, err := BuildPreview(t.Context(), "my-dev", store, client)
	if err != nil {
		t.Fatalf("BuildPreview: %v", err)
	}
	if preview == nil {
		t.Fatal("expected non-nil preview for tmux session")
	}
	if preview.Status != "tmux" {
		t.Errorf("status: got %q, want %q", preview.Status, "tmux")
	}
	if len(preview.PaneLines) == 0 {
		t.Error("expected pane lines for live tmux session")
	}
}

func TestBuildPreview_TmuxSession_Dead(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	store := state.OpenStore(root)

	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) > 0 && args[0] == "has-session" {
			return "", &tmux.ExitError{Code: 1} // not alive
		}
		return "", nil
	}}
	client := tmux.NewClient(runner)

	preview, err := BuildPreview(t.Context(), "dead-sess", store, client)
	if err != nil {
		t.Fatalf("BuildPreview: %v", err)
	}
	if preview != nil {
		t.Error("expected nil preview for dead non-party session")
	}
}

// ---------------------------------------------------------------------------
// Tab navigation tests
// ---------------------------------------------------------------------------

func TestSwitchTab_CyclesForward(t *testing.T) {
	t.Parallel()

	m := Model{
		active:    []Entry{{SessionID: "a"}},
		resumable: []Entry{{SessionID: "b"}},
		tmux:      []Entry{{SessionID: "c"}},
		tab:       tabActive,
	}

	m.switchTab(true)
	if m.tab != tabTmux {
		t.Errorf("after first forward: got tab %d, want %d", m.tab, tabTmux)
	}
	m.switchTab(true)
	if m.tab != tabResumable {
		t.Errorf("after second forward: got tab %d, want %d", m.tab, tabResumable)
	}
	m.switchTab(true)
	if m.tab != tabActive {
		t.Errorf("after third forward (wrap): got tab %d, want %d", m.tab, tabActive)
	}
}

func TestSwitchTab_CyclesBackward(t *testing.T) {
	t.Parallel()

	m := Model{
		active:    []Entry{{SessionID: "a"}},
		resumable: []Entry{{SessionID: "b"}},
		tmux:      []Entry{{SessionID: "c"}},
		tab:       tabActive,
	}

	m.switchTab(false)
	if m.tab != tabResumable {
		t.Errorf("after backward from Active: got tab %d, want %d", m.tab, tabResumable)
	}
	m.switchTab(false)
	if m.tab != tabTmux {
		t.Errorf("after backward from Resumable: got tab %d, want %d", m.tab, tabTmux)
	}
}

func TestSwitchTab_IncludesEmptyTabs(t *testing.T) {
	t.Parallel()

	m := Model{
		active: []Entry{{SessionID: "a"}},
		tmux:   []Entry{{SessionID: "c"}},
		tab:    tabActive,
	}

	// Should visit empty Resumable tab (all tabs navigable).
	m.switchTab(true)
	if m.tab != tabTmux {
		t.Errorf("forward should continue to tmux: got tab %d, want %d", m.tab, tabTmux)
	}
	m.switchTab(true)
	if m.tab != tabResumable {
		t.Errorf("forward should include empty resumable: got tab %d, want %d", m.tab, tabResumable)
	}
	m.switchTab(true)
	if m.tab != tabActive {
		t.Errorf("forward should wrap back: got tab %d, want %d", m.tab, tabActive)
	}
}

func TestSwitchTab_AllEmpty_StillCycles(t *testing.T) {
	t.Parallel()

	m := Model{tab: tabActive}

	m.switchTab(true)
	if m.tab != tabTmux {
		t.Errorf("should cycle even with all tabs empty: got tab %d, want %d", m.tab, tabTmux)
	}
	m.switchTab(true)
	if m.tab != tabResumable {
		t.Errorf("should reach resumable: got tab %d, want %d", m.tab, tabResumable)
	}
}

func TestFirstNonEmptyTab(t *testing.T) {
	t.Parallel()

	cases := map[string]struct {
		active, resumable, tmux []Entry
		want                    tab
	}{
		"active first":    {active: []Entry{{SessionID: "a"}}, want: tabActive},
		"resumable first": {resumable: []Entry{{SessionID: "b"}}, want: tabResumable},
		"tmux first":      {tmux: []Entry{{SessionID: "c"}}, want: tabTmux},
		"all empty":       {want: tabActive},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			m := Model{active: tc.active, resumable: tc.resumable, tmux: tc.tmux}
			got := m.firstNonEmptyTab()
			if got != tc.want {
				t.Errorf("got %d, want %d", got, tc.want)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// FormatEntries ANSI token tests
// ---------------------------------------------------------------------------

func TestFormatEntries_ActiveUsesCleanDot(t *testing.T) {
	t.Parallel()
	entries := []Entry{
		{SessionID: "party-test", Status: "active", Title: "test", Cwd: "/tmp"},
	}
	got := FormatEntries(entries)

	// Active entries get a green status dot.
	cleanANSI := "\033[32m"
	if !strings.Contains(got, cleanANSI+"● ") {
		t.Errorf("FormatEntries active entry should have green dot (\\033[32m● ), got:\n%s", got)
	}
}

func TestFormatEntries_MasterUsesGoldDot(t *testing.T) {
	t.Parallel()
	entries := []Entry{
		{SessionID: "party-master", Status: "master (2)", Title: "m", Cwd: "/tmp"},
	}
	got := FormatEntries(entries)

	goldDot := renderANSI(lipgloss.NewStyle().Foreground(palette.MasterRole), "● ")
	if !strings.Contains(got, goldDot) {
		t.Errorf("FormatEntries master entry should have gold dot, got:\n%s", got)
	}
}

func TestFormatEntries_TruncatesLongTitle(t *testing.T) {
	t.Parallel()
	longTitle := strings.Repeat("x", 60)
	entries := []Entry{
		{SessionID: "party-test", Status: "active", Title: longTitle, Cwd: "/tmp"},
	}
	got := FormatEntries(entries)

	// Title column is 28 chars wide; long title must be truncated with "…".
	if strings.Contains(got, longTitle) {
		t.Error("FormatEntries should truncate long titles, but found full title in output")
	}
	if !strings.Contains(got, "…") {
		t.Error("FormatEntries should use … for truncated titles")
	}
}

func TestFormatEntries_ShowsPrimaryAgentColumn(t *testing.T) {
	t.Parallel()
	entries := []Entry{
		{SessionID: "party-test", Status: "active", Title: "test", PrimaryAgent: "claude", Cwd: "/tmp"},
	}
	got := FormatEntries(entries)

	if !strings.Contains(got, "claude") {
		t.Fatalf("FormatEntries should show primary agent, got:\n%s", got)
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

	divider := renderANSI(lipgloss.NewStyle().Foreground(palette.DividerFg), "  ── resumable ─────────────────────────────────────────────")
	if !strings.Contains(got, divider) {
		t.Errorf("FormatEntries resumable divider should use DividerFg styling, got:\n%s", got)
	}
}

// ---------------------------------------------------------------------------
// FormatPreview ANSI token tests
// ---------------------------------------------------------------------------

func TestFormatPreview_MasterUsesGoldANSI(t *testing.T) {
	t.Parallel()
	pd := &PreviewData{Status: "master", WorkerCount: 2, Cwd: "/tmp", Timestamp: "2026-03-10"}
	got := FormatPreview(pd)

	goldANSI := renderANSI(lipgloss.NewStyle().Foreground(palette.MasterRole).Bold(true), "● master")
	if !strings.Contains(got, goldANSI) {
		t.Errorf("FormatPreview master status should use Gold ANSI, got:\n%s", got)
	}
	if !strings.Contains(got, "● master") {
		t.Errorf("FormatPreview master should show status dot, got:\n%s", got)
	}
	if !strings.Contains(got, "2 workers") {
		t.Errorf("FormatPreview master should show worker count, got:\n%s", got)
	}
}

func TestFormatPreview_ActiveUsesCleanANSI(t *testing.T) {
	t.Parallel()
	pd := &PreviewData{Status: "active", Cwd: "/tmp", Timestamp: "2026-03-10", PrimaryAgent: "claude", Prompt: "fix bug"}
	got := FormatPreview(pd)

	cleanANSI := "\033[32m"
	if !strings.Contains(got, cleanANSI) {
		t.Errorf("FormatPreview active status should use Clean ANSI 2, got:\n%s", got)
	}
	if !strings.Contains(got, "● active") {
		t.Errorf("FormatPreview active should show status dot, got:\n%s", got)
	}
	if !strings.Contains(got, "claude") {
		t.Errorf("FormatPreview should show primary agent, got:\n%s", got)
	}
	if !strings.Contains(got, "fix bug") {
		t.Errorf("FormatPreview should show prompt text, got:\n%s", got)
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
	if !strings.Contains(got, mutedANSI+"○ resumable") {
		t.Errorf("FormatPreview resumable status should use Muted ANSI 8 with hollow dot, got:\n%s", got)
	}
	if !strings.Contains(got, "/tmp/project") {
		t.Errorf("FormatPreview should show cwd, got:\n%s", got)
	}
	if !strings.Contains(got, "2026-03-05T10:00:00Z") {
		t.Errorf("FormatPreview should show timestamp, got:\n%s", got)
	}
	if !strings.Contains(got, "claude-abc") {
		t.Errorf("FormatPreview should show claude ID, got:\n%s", got)
	}
	if !strings.Contains(got, "codex-xyz") {
		t.Errorf("FormatPreview should show wizard ID, got:\n%s", got)
	}
}

func TestFormatPreview_PaladinSectionUsesAccentANSI(t *testing.T) {
	t.Parallel()
	pd := &PreviewData{
		Status:    "active",
		Cwd:       "/tmp",
		Timestamp: "2026-03-10",
		PaneLines: []string{"❯ git status", "some output"},
	}
	got := FormatPreview(pd)

	accentANSI := renderANSI(lipgloss.NewStyle().Foreground(palette.Accent).Bold(true), "paladin")
	if !strings.Contains(got, accentANSI) {
		t.Errorf("FormatPreview should use Accent ANSI for paladin section header, got:\n%s", got)
	}
	if !strings.Contains(got, "paladin") {
		t.Errorf("FormatPreview should have paladin section header, got:\n%s", got)
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

func TestFormatEntries_TmuxUsesAccentDot(t *testing.T) {
	t.Parallel()
	entries := []Entry{
		{SessionID: "my-dev", Status: "tmux", Title: "my-dev", Cwd: "/tmp"},
	}
	got := FormatEntries(entries)

	accentANSI := "\033[34m"
	if !strings.Contains(got, accentANSI+"● ") {
		t.Errorf("FormatEntries tmux entry should have accent (blue) dot, got:\n%s", got)
	}
}

func TestFormatPreview_TmuxUsesAccentANSI(t *testing.T) {
	t.Parallel()
	pd := &PreviewData{
		Status:    "tmux",
		Cwd:       "/home/user/code",
		PaneLines: []string{"$ ls", "file1.txt"},
	}
	got := FormatPreview(pd)

	accentANSI := renderANSI(lipgloss.NewStyle().Foreground(palette.Accent).Bold(true), "● tmux")
	if !strings.Contains(got, accentANSI) {
		t.Errorf("FormatPreview tmux status should use Accent ANSI, got:\n%s", got)
	}
	if !strings.Contains(got, "● tmux") {
		t.Errorf("FormatPreview tmux should show status dot, got:\n%s", got)
	}
}

func TestEntryTypeLabel_Tmux(t *testing.T) {
	t.Parallel()
	e := Entry{Status: "tmux"}
	got := entryTypeLabel(&e)
	if got != "tmux" {
		t.Errorf("entryTypeLabel: got %q, want %q", got, "tmux")
	}
}

func renderANSI(style lipgloss.Style, text string) string {
	r := lipgloss.NewRenderer(io.Discard)
	r.SetColorProfile(termenv.ANSI)
	return r.NewStyle().Inherit(style).Render(text)
}
