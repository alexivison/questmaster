package picker

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
	"github.com/muesli/termenv"

	"github.com/alexivison/questmaster/internal/palette"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tui"
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
	if err := os.WriteFile(filepath.Join(root, m.SessionID+".json"), data, 0o644); err != nil {
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
		SessionID: "qm-standalone", Title: "standalone", Cwd: "/tmp/a",
		Agents: []state.AgentManifest{{Name: "claude", Role: "primary"}},
	})
	writeManifest(t, root, state.Manifest{
		SessionID: "qm-master", Title: "master-sess", Cwd: "/tmp/b",
		SessionType: "master", Workers: []string{"qm-worker"},
		Agents: []state.AgentManifest{{Name: "codex", Role: "primary"}},
	})
	writeManifest(t, root, state.Manifest{
		SessionID: "qm-worker", Title: "worker-sess", Cwd: "/tmp/c",
		Agents: []state.AgentManifest{{Name: "claude", Role: "primary"}},
		Extra:  map[string]json.RawMessage{"parent_session": json.RawMessage(`"qm-master"`)},
	})
	writeManifest(t, root, state.Manifest{
		SessionID: "qm-stale", Title: "stale-sess", Cwd: "/tmp/d",
		CreatedAt: "2026-03-01T00:00:00Z",
	})

	store := state.OpenStore(root)

	// Mock tmux: qm-standalone, qm-master, qm-worker are live
	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) > 0 && args[0] == "list-sessions" {
			return "qm-standalone\nqm-master\nqm-worker\nnon-qm-sess", nil
		}
		if len(args) > 0 && args[0] == "display-message" {
			return "qm-standalone", nil // current session
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
		if e.SessionID == "qm-standalone" && e.Status == "* current" {
			found = true
			break
		}
	}
	if !found {
		t.Error("standalone should be marked as current session")
	}

	// Master entry should include worker count
	for _, e := range entries {
		if e.SessionID == "qm-master" {
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
		if e.SessionID == "  qm-worker" {
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
		if e.SessionID == "qm-stale" {
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
		SessionID: "qm-orphan", Title: "orphan", Cwd: "/tmp/o",
		Extra: map[string]json.RawMessage{"parent_session": json.RawMessage(`"qm-dead-master"`)},
	})

	store := state.OpenStore(root)
	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) > 0 && args[0] == "list-sessions" {
			return "qm-orphan", nil
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
		if e.SessionID == "qm-orphan" && e.Status == "worker (orphan)" {
			found = true
		}
	}
	if !found {
		t.Error("expected orphan worker entry with 'worker (orphan)' status")
	}
}

// ---------------------------------------------------------------------------
// Preview removal tests
// ---------------------------------------------------------------------------

func TestModelDoesNotLoadPreviewOnInitOrNavigation(t *testing.T) {
	t.Parallel()

	m := NewModel(context.Background(), []Entry{
		{SessionID: "qm-a", Status: "active"},
		{SessionID: "qm-b", Status: "active"},
	}, nil, nil, nil, nil, AgentOptions{})

	if cmd := m.Init(); cmd != nil {
		t.Fatalf("picker Init should not schedule preview loading, got %v", cmd)
	}

	model, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'j'}})
	m = model.(Model)
	if cmd != nil {
		t.Fatalf("navigation should not schedule preview loading, got %v", cmd)
	}
	if got := *m.currentCursor(); got != 1 {
		t.Fatalf("cursor after j = %d, want 1", got)
	}
}

func TestModelDeleteCurrent_LastEntryDoesNotSchedulePreview(t *testing.T) {
	t.Parallel()

	root := t.TempDir()
	store, err := state.NewStore(root)
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	if err := store.Create(state.Manifest{
		SessionID: "qm-delete",
		Title:     "delete-me",
		Cwd:       "/tmp/delete-me",
	}); err != nil {
		t.Fatalf("create manifest: %v", err)
	}

	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		switch args[0] {
		case "list-sessions":
			switch args[len(args)-1] {
			case "#{session_name}":
				return "qm-delete", nil
			case "#{session_name}\t#{pane_current_path}":
				return "qm-delete\t/tmp/delete-me", nil
			}
		case "display-message":
			return "some-other-session", nil
		}
		return "", nil
	}}
	client := tmux.NewClient(runner)

	entries, err := BuildEntries(t.Context(), store, client)
	if err != nil {
		t.Fatalf("BuildEntries: %v", err)
	}
	m := NewModel(
		t.Context(),
		entries,
		store,
		client,
		func(_ context.Context, sessionID string) error { return store.Delete(sessionID) },
		nil,
		AgentOptions{},
	)

	model, deleteCmd := m.Update(tea.KeyMsg{Type: tea.KeyCtrlD})
	m = model.(Model)
	if deleteCmd == nil {
		t.Fatal("ctrl+d should schedule a delete")
	}

	model, reloadCmd := m.Update(deleteCmd())
	m = model.(Model)
	if reloadCmd == nil {
		t.Fatal("delete should trigger a reload")
	}

	model, followup := m.Update(reloadCmd())
	m = model.(Model)
	if followup != nil {
		t.Fatalf("empty list should not schedule preview loading, got %v", followup)
	}
	if len(m.active) != 0 {
		t.Fatalf("active entries = %d, want 0", len(m.active))
	}
}

func TestModelDeleteCurrent_CurrentSessionNoOps(t *testing.T) {
	t.Parallel()

	m := NewModel(context.Background(), []Entry{
		{SessionID: "qm-current", Status: "* current", Title: "current"},
	}, nil, nil, nil, nil, AgentOptions{})

	model, cmd := m.Update(tea.KeyMsg{Type: tea.KeyCtrlD})
	m = model.(Model)

	if cmd != nil {
		t.Fatalf("ctrl+d on the current session should not schedule a delete, got %v", cmd)
	}
}

func TestBuildEntries_OrderMatchesTracker(t *testing.T) {
	t.Parallel()
	root := t.TempDir()

	writeManifest(t, root, state.Manifest{
		SessionID:   "qm-master-new",
		Title:       "master-new",
		Cwd:         "/tmp/master-new",
		SessionType: "master",
		Workers:     []string{"qm-worker-new"},
		CreatedAt:   "2026-03-05T12:00:00Z",
	})
	writeManifest(t, root, state.Manifest{
		SessionID: "qm-worker-new",
		Title:     "worker-new",
		Cwd:       "/tmp/worker-new",
		CreatedAt: "2026-03-04T12:00:00Z",
		Extra: map[string]json.RawMessage{
			"parent_session": json.RawMessage(`"qm-master-new"`),
		},
	})
	writeManifest(t, root, state.Manifest{
		SessionID: "qm-standalone",
		Title:     "standalone",
		Cwd:       "/tmp/standalone",
		CreatedAt: "2026-03-03T12:00:00Z",
	})
	writeManifest(t, root, state.Manifest{
		SessionID:   "qm-master-old",
		Title:       "master-old",
		Cwd:         "/tmp/master-old",
		SessionType: "master",
		Workers:     []string{"qm-worker-old"},
		CreatedAt:   "2026-03-02T12:00:00Z",
	})
	writeManifest(t, root, state.Manifest{
		SessionID: "qm-worker-old",
		Title:     "worker-old",
		Cwd:       "/tmp/worker-old",
		CreatedAt: "2026-03-01T12:00:00Z",
		Extra: map[string]json.RawMessage{
			"parent_session": json.RawMessage(`"qm-master-old"`),
		},
	})

	store := state.OpenStore(root)
	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		switch args[0] {
		case "list-sessions":
			return strings.Join([]string{
				"qm-worker-old",
				"qm-standalone",
				"qm-master-new",
				"qm-worker-new",
				"qm-master-old",
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
// Tab navigation tests
// ---------------------------------------------------------------------------

func TestSwitchTab_CyclesBetweenQuestmasterTabs(t *testing.T) {
	t.Parallel()

	m := Model{
		active:    []Entry{{SessionID: "a"}},
		resumable: []Entry{{SessionID: "b"}},
		tab:       tabActive,
	}

	m.switchTab(true)
	if m.tab != tabResumable {
		t.Errorf("after first forward: got tab %d, want %d", m.tab, tabResumable)
	}
	m.switchTab(true)
	if m.tab != tabActive {
		t.Errorf("after second forward (wrap): got tab %d, want %d", m.tab, tabActive)
	}

	m.switchTab(false)
	if m.tab != tabResumable {
		t.Errorf("after backward from Active: got tab %d, want %d", m.tab, tabResumable)
	}
}

func TestSwitchTab_IncludesEmptyResumableTab(t *testing.T) {
	t.Parallel()

	m := Model{
		active: []Entry{{SessionID: "a"}},
		tab:    tabActive,
	}

	m.switchTab(true)
	if m.tab != tabResumable {
		t.Errorf("forward should visit empty resumable tab: got tab %d, want %d", m.tab, tabResumable)
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
	if m.tab != tabResumable {
		t.Errorf("should reach resumable: got tab %d, want %d", m.tab, tabResumable)
	}
}

func TestFirstNonEmptyTab(t *testing.T) {
	t.Parallel()

	cases := map[string]struct {
		active, resumable []Entry
		want              tab
	}{
		"active first":    {active: []Entry{{SessionID: "a"}}, want: tabActive},
		"resumable first": {resumable: []Entry{{SessionID: "b"}}, want: tabResumable},
		"all empty":       {want: tabActive},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			m := Model{active: tc.active, resumable: tc.resumable}
			got := m.firstNonEmptyTab()
			if got != tc.want {
				t.Errorf("got %d, want %d", got, tc.want)
			}
		})
	}
}

func TestPickerView_HasNoTmuxTab(t *testing.T) {
	t.Parallel()

	m := Model{
		active:    []Entry{{SessionID: "qm-a", Status: "active", Title: "alpha"}},
		resumable: []Entry{{SessionID: "qm-b", Status: "resumable", Title: "beta"}},
		width:     100,
		height:    10,
	}

	view := m.View()
	if strings.Contains(view, "Tmux") {
		t.Fatalf("picker view should not render a Tmux tab, got:\n%s", view)
	}
}

func TestHandleKey_NumberKeysJumpWithinFirstNineRows(t *testing.T) {
	t.Parallel()

	for size := 1; size <= 9; size++ {
		t.Run(fmt.Sprintf("size_%d", size), func(t *testing.T) {
			t.Parallel()

			entries := make([]Entry, size)
			for i := range size {
				entries[i] = Entry{
					SessionID: fmt.Sprintf("qm-%d", i+1),
					Status:    "active",
					Title:     fmt.Sprintf("session-%d", i+1),
				}
			}

			m := NewModel(context.Background(), entries, nil, nil, nil, nil, AgentOptions{})
			for key := 1; key <= size; key++ {
				model, cmd := m.Update(tea.KeyMsg{
					Type:  tea.KeyRunes,
					Runes: []rune{rune('0' + key)},
				})
				m = model.(Model)

				if got := *m.currentCursor(); got != key-1 {
					t.Fatalf("cursor after %d = %d, want %d", key, got, key-1)
				}
				if cmd == nil {
					t.Fatalf("number key %d should quit", key)
				}
				if got := m.Selected(); got != fmt.Sprintf("qm-%d", key) {
					t.Fatalf("selected after %d = %q, want %q", key, got, fmt.Sprintf("qm-%d", key))
				}
				if _, ok := cmd().(tea.QuitMsg); !ok {
					t.Fatalf("number key %d should return tea.Quit", key)
				}
			}
		})
	}
}

func TestHandleKey_NumberKeyOutOfRangeNoOps(t *testing.T) {
	t.Parallel()

	m := NewModel(context.Background(), []Entry{
		{SessionID: "qm-1", Status: "active", Title: "one"},
		{SessionID: "qm-2", Status: "active", Title: "two"},
		{SessionID: "qm-3", Status: "active", Title: "three"},
	}, nil, nil, nil, nil, AgentOptions{})
	m.cursor[tabActive] = 1

	model, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'9'}})
	m = model.(Model)

	if got := *m.currentCursor(); got != 1 {
		t.Fatalf("cursor after out-of-range jump = %d, want 1", got)
	}
	if cmd != nil {
		t.Fatalf("out-of-range number key should be a no-op, got %v", cmd)
	}
	if got := m.Selected(); got != "" {
		t.Fatalf("selected after out-of-range jump = %q, want empty", got)
	}
}

func TestHandleKey_NumberKeyOnEmptyListNoOps(t *testing.T) {
	t.Parallel()

	m := NewModel(context.Background(), nil, nil, nil, nil, nil, AgentOptions{})

	model, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'1'}})
	m = model.(Model)

	if got := *m.currentCursor(); got != 0 {
		t.Fatalf("cursor after empty-list jump = %d, want 0", got)
	}
	if cmd != nil {
		t.Fatalf("empty-list number key should be a no-op, got %v", cmd)
	}
	if got := m.Selected(); got != "" {
		t.Fatalf("selected after empty-list jump = %q, want empty", got)
	}
}

// PickerEntryStyle ANSI token tests
// ---------------------------------------------------------------------------

func TestEntryGlyph_WorkerUsesTreeConnector(t *testing.T) {
	origProfile := lipgloss.ColorProfile()
	lipgloss.SetColorProfile(termenv.ANSI)
	t.Cleanup(func() {
		lipgloss.SetColorProfile(origProfile)
	})

	entry := Entry{Status: "worker"}
	rawLast, styledLast := entryGlyph(&entry, nil)
	if rawLast != "┗━ " {
		t.Errorf("entryGlyph last worker raw glyph = %q, want %q", rawLast, "┗━ ")
	}
	wantLast := renderANSI(lipgloss.NewStyle().Foreground(palette.DividerBorder), "┗━ ")
	if styledLast != wantLast {
		t.Errorf("entryGlyph last worker styled glyph = %q, want %q", styledLast, wantLast)
	}

	nextWorker := Entry{Status: "worker"}
	rawBranch, styledBranch := entryGlyph(&entry, &nextWorker)
	if rawBranch != "┣━ " {
		t.Errorf("entryGlyph non-last worker raw glyph = %q, want %q", rawBranch, "┣━ ")
	}
	wantBranch := renderANSI(lipgloss.NewStyle().Foreground(palette.DividerBorder), "┣━ ")
	if styledBranch != wantBranch {
		t.Errorf("entryGlyph non-last worker styled glyph = %q, want %q", styledBranch, wantBranch)
	}
}

func TestWorkerConnector_OrphanNextIsTreatedAsEndOfGroup(t *testing.T) {
	t.Parallel()
	orphan := Entry{Status: "worker (orphan)"}
	if got := workerConnector(&orphan); got != "┗━ " {
		t.Errorf("workerConnector with orphan next = %q, want %q", got, "┗━ ")
	}
	master := Entry{Status: "master (1)"}
	if got := workerConnector(&master); got != "┗━ " {
		t.Errorf("workerConnector with master next = %q, want %q", got, "┗━ ")
	}
}

func TestRenderRow_SelectedWorkerKeepsConnectorGlyph(t *testing.T) {
	t.Parallel()
	worker := Entry{
		SessionID: "qm-worker",
		Status:    "worker",
		Title:     "child",
		Cwd:       "/tmp",
	}
	m := Model{}
	out := m.renderRow(&worker, nil, 0, true, 120)
	if !strings.Contains(out, "┗━") {
		t.Fatalf("selected last worker row should include ┗━ connector, got %q", out)
	}

	next := Entry{Status: "worker"}
	out = m.renderRow(&worker, &next, 0, true, 120)
	if !strings.Contains(out, "┣━") {
		t.Fatalf("selected non-last worker row should include ┣━ connector, got %q", out)
	}
	if !strings.Contains(out, "┃") {
		t.Fatalf("selected non-last worker row should include continuation connector, got %q", out)
	}
}

func TestRenderRow_WorkerConnectorReflectsNextEntry(t *testing.T) {
	t.Parallel()
	worker := Entry{
		SessionID: "qm-worker",
		Status:    "worker",
		Title:     "child",
		Cwd:       "/tmp",
	}
	m := Model{}

	nextWorker := Entry{Status: "worker"}
	branch := m.renderRow(&worker, &nextWorker, 0, false, 120)
	if !strings.Contains(branch, "┣━") {
		t.Fatalf("unselected non-last worker row should include ┣━ connector, got %q", branch)
	}
	if !strings.Contains(branch, "┃") {
		t.Fatalf("unselected non-last worker row should include continuation connector, got %q", branch)
	}

	end := m.renderRow(&worker, nil, 0, false, 120)
	if !strings.Contains(end, "┗━") {
		t.Fatalf("unselected last worker row should include ┗━ connector, got %q", end)
	}
	if strings.Contains(end, "┃") {
		t.Fatalf("last worker row should not include continuation connector, got %q", end)
	}
}

func TestRenderRow_TitleLineAndMetadataLine(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name     string
		entry    Entry
		wantLine []string
		wantMeta []string
	}{
		{
			name: "master",
			entry: Entry{
				SessionID:    "qm-root",
				Status:       "master (2)",
				Title:        "overseer",
				Cwd:          "/tmp/root",
				PrimaryAgent: "codex",
			},
			wantLine: []string{"\uf44f", "overseer"},
			wantMeta: []string{"⚔", "qm-root", "\uf114", "/tmp/root"},
		},
		{
			name: "standalone",
			entry: Entry{
				SessionID:    "qm-solo",
				Status:       "active",
				Title:        "solo",
				Cwd:          "/tmp/solo",
				PrimaryAgent: "claude",
			},
			wantLine: []string{"\U000f06c4", "solo"},
			wantMeta: []string{"✠", "qm-solo", "\uf114", "/tmp/solo"},
		},
		{
			name: "worker",
			entry: Entry{
				SessionID:    "qm-worker",
				Status:       "worker",
				Title:        "child",
				Cwd:          "/tmp/child",
				PrimaryAgent: "pi",
			},
			wantLine: []string{"┗━", "\u03c0", "child"},
			wantMeta: []string{"⚒", "qm-worker", "\uf114", "/tmp/child"},
		},
		{
			name: "unknown agent",
			entry: Entry{
				SessionID:    "qm-solo",
				Status:       "active",
				Title:        "solo",
				Cwd:          "/tmp/solo",
				PrimaryAgent: "unknown",
			},
			wantLine: []string{"solo"},
			wantMeta: []string{"✠", "qm-solo", "\uf114", "/tmp/solo"},
		},
	}

	m := Model{}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			lines := strings.Split(ansi.Strip(m.renderRow(&tt.entry, nil, 0, false, 140)), "\n")
			if len(lines) != 2 {
				t.Fatalf("rendered row line count = %d, want 2: %q", len(lines), lines)
			}
			gotLine := strings.Fields(lines[0])
			gotMeta := strings.Fields(lines[1])
			if !reflect.DeepEqual(gotLine, tt.wantLine) {
				t.Fatalf("title line fields = %v, want %v", gotLine, tt.wantLine)
			}
			if !reflect.DeepEqual(gotMeta, tt.wantMeta) {
				t.Fatalf("metadata line fields = %v, want %v", gotMeta, tt.wantMeta)
			}
			if !strings.Contains(lines[1], tt.wantMeta[1]+"  \uf114") {
				t.Fatalf("metadata line should separate session id and folder with two spaces, got %q", lines[1])
			}
			if tt.entry.PrimaryAgent != "" && contains(gotMeta, tt.entry.PrimaryAgent) {
				t.Fatalf("metadata line should not include separate agent column, got %v", gotMeta)
			}
		})
	}
}

func TestRenderRow_AgentIconUsesTrackerColors(t *testing.T) {
	origProfile := lipgloss.ColorProfile()
	lipgloss.SetColorProfile(termenv.TrueColor)
	t.Cleanup(func() {
		lipgloss.SetColorProfile(origProfile)
	})

	tests := []struct {
		agent string
		icon  string
		color lipgloss.Color
	}{
		{agent: "claude", icon: "\U000f06c4", color: palette.ClaudeColor},
		{agent: "codex", icon: "\uf44f", color: palette.CodexColor},
		{agent: "pi", icon: "\u03c0", color: palette.PiColor},
	}

	m := Model{}
	for _, tt := range tests {
		t.Run(tt.agent, func(t *testing.T) {
			entry := Entry{
				SessionID:    "qm-" + tt.agent,
				Status:       "active",
				Title:        tt.agent,
				Cwd:          "/tmp/" + tt.agent,
				PrimaryAgent: tt.agent,
			}
			got := m.renderRow(&entry, nil, 0, false, 120)
			want := renderTrueColorANSI(lipgloss.NewStyle().Foreground(tt.color), tt.icon)
			if !strings.Contains(got, want) {
				t.Fatalf("rendered row should contain %s icon in tracker color\nwant %q\ngot  %q", tt.agent, want, got)
			}
		})
	}
}

func TestPickerView_HasNoPreviewPaneOrDivider(t *testing.T) {
	t.Parallel()

	m := NewModel(context.Background(), []Entry{{
		SessionID:    "qm-1",
		Status:       "active",
		Title:        "alpha",
		Cwd:          "/tmp/project",
		PrimaryAgent: "claude",
	}}, nil, nil, nil, nil, AgentOptions{})

	model, _ := m.Update(tea.WindowSizeMsg{Width: 80, Height: 8})
	m = model.(Model)

	view := m.View()
	if strings.Contains(view, "│") {
		t.Fatalf("picker view should not render a vertical preview divider, got:\n%s", view)
	}
	if strings.Contains(view, "No manifest found") || strings.Contains(view, "● active") {
		t.Fatalf("picker view should not render preview content, got:\n%s", view)
	}
}

func TestPickerContentWidth(t *testing.T) {
	t.Parallel()

	tests := []struct {
		width int
		want  int
	}{
		{width: 0, want: 0},
		{width: 24, want: 24},
		{width: 48, want: 48},
		{width: 80, want: 48},
		{width: 100, want: 60},
		{width: 160, want: 96},
		{width: 220, want: 96},
	}

	for _, tt := range tests {
		t.Run(fmt.Sprintf("width_%d", tt.width), func(t *testing.T) {
			t.Parallel()

			if got := pickerContentWidth(tt.width); got != tt.want {
				t.Fatalf("pickerContentWidth(%d) = %d, want %d", tt.width, got, tt.want)
			}
		})
	}
}

func TestPickerView_UsesContentWidthForFrame(t *testing.T) {
	t.Parallel()

	m := NewModel(context.Background(), []Entry{{
		SessionID:    "qm-1",
		Status:       "active",
		Title:        "alpha",
		Cwd:          "/tmp/project",
		PrimaryAgent: "claude",
	}}, nil, nil, nil, nil, AgentOptions{})

	model, _ := m.Update(tea.WindowSizeMsg{Width: 100, Height: 8})
	m = model.(Model)

	contentW := pickerContentWidth(m.width)
	if contentW >= m.width {
		t.Fatalf("test setup expected constrained content width, got content %d terminal %d", contentW, m.width)
	}

	for i, line := range strings.Split(m.View(), "\n") {
		if got := lipgloss.Width(line); got != contentW {
			t.Fatalf("view line %d width = %d, want %d\n%s", i, got, contentW, m.View())
		}
	}
}

func TestViewSelectedRowTintUsesContentWidth(t *testing.T) {
	lipgloss.SetColorProfile(termenv.TrueColor)
	t.Cleanup(func() {
		lipgloss.SetColorProfile(termenv.Ascii)
	})

	entry := Entry{
		SessionID:    "qm-1",
		Status:       "active",
		Title:        "alpha",
		Cwd:          "/tmp/project",
		PrimaryAgent: "claude",
	}
	m := NewModel(context.Background(), []Entry{entry}, nil, nil, nil, nil, AgentOptions{})

	model, _ := m.Update(tea.WindowSizeMsg{Width: 80, Height: 8})
	m = model.(Model)

	view := m.View()
	lines := strings.Split(view, "\n")
	if len(lines) < 3 {
		t.Fatalf("picker view line count = %d, want at least 3\n%s", len(lines), view)
	}

	raw := renderTrueColorANSI(pickerSelectedStyle, strings.Repeat(" ", padLeft)) +
		selectedTitleCell(entry.Title, entry.PrimaryAgent)

	contentW := pickerContentWidth(m.width)
	expected := fitSelectedToWidth(raw, contentW)
	if lines[2] != expected {
		t.Fatalf("selected row should stay tinted to content width\nwant %q\ngot  %q", expected, lines[2])
	}
	if got := lipgloss.Width(lines[2]); got != contentW {
		t.Fatalf("selected row width = %d, want %d", got, contentW)
	}
}

func TestRenderRow_NumberPrefixRemoved(t *testing.T) {
	t.Parallel()

	entry := Entry{
		SessionID: "qm-1",
		Status:    "active",
		Title:     "alpha",
		Cwd:       "/tmp/project",
	}
	m := Model{}

	for _, index := range []int{0, 8, 9} {
		row := ansi.Strip(m.renderRow(&entry, nil, index, false, 120))
		if strings.Contains(row, fmt.Sprintf("%d. ", index+1)) {
			t.Fatalf("row %d should not include a numeric prefix, got %q", index, row)
		}
	}
}

func renderANSI(style lipgloss.Style, text string) string {
	r := lipgloss.NewRenderer(io.Discard)
	r.SetColorProfile(termenv.ANSI)
	return r.NewStyle().Inherit(style).Render(text)
}

func renderTrueColorANSI(style lipgloss.Style, text string) string {
	r := lipgloss.NewRenderer(io.Discard)
	r.SetColorProfile(termenv.TrueColor)
	return r.NewStyle().Inherit(style).Render(text)
}

func contains(values []string, want string) bool {
	for _, value := range values {
		if value == want {
			return true
		}
	}
	return false
}
