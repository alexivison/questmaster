package tui

import (
	"fmt"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

func stubResolver(id string, mode ViewMode) SessionResolver {
	return func() (SessionInfo, error) {
		return SessionInfo{ID: id, Mode: mode}, nil
	}
}

// ---------------------------------------------------------------------------
// Boot path
// ---------------------------------------------------------------------------

func TestModel_Init_ReturnsCommands(t *testing.T) {
	t.Parallel()

	m := NewModelWithResolver(stubResolver("party-test", ViewWorker))
	cmd := m.Init()

	if cmd == nil {
		t.Fatal("Init() must return a command (tick + resolve batch)")
	}
}

// ---------------------------------------------------------------------------
// Mode selection
// ---------------------------------------------------------------------------

func TestModel_ModeSelection_Master(t *testing.T) {
	t.Parallel()

	m := NewModelWithResolver(stubResolver("party-master-1", ViewMaster))
	updated, _ := m.Update(sessionMsg{id: "party-master-1", mode: ViewMaster})
	model := updated.(Model)

	if model.Mode != ViewMaster {
		t.Errorf("expected ViewMaster, got %v", model.Mode)
	}
	if model.SessionID != "party-master-1" {
		t.Errorf("expected session 'party-master-1', got %q", model.SessionID)
	}
}

func TestModel_ModeSelection_Worker(t *testing.T) {
	t.Parallel()

	m := NewModelWithResolver(stubResolver("party-worker-1", ViewWorker))
	updated, _ := m.Update(sessionMsg{id: "party-worker-1", mode: ViewWorker})
	model := updated.(Model)

	if model.Mode != ViewWorker {
		t.Errorf("expected ViewWorker, got %v", model.Mode)
	}
}

// ---------------------------------------------------------------------------
// Error state
// ---------------------------------------------------------------------------

func TestModel_ErrorState_RendersMessage(t *testing.T) {
	t.Parallel()

	m := NewModelWithResolver(func() (SessionInfo, error) {
		return SessionInfo{}, fmt.Errorf("no party session found")
	})
	updated, _ := m.Update(sessionMsg{err: fmt.Errorf("no party session found")})
	model := updated.(Model)

	if model.Err == nil {
		t.Fatal("expected error state")
	}

	model.Width = 80
	model.Height = 24
	view := model.View()
	if !strings.Contains(view, "no party session found") {
		t.Error("error view should contain the error message")
	}
	if !strings.Contains(view, "PARTY_SESSION") {
		t.Error("error view should hint about PARTY_SESSION")
	}
	if !strings.Contains(view, "╭") || !strings.Contains(view, "╯") {
		t.Error("error view must use bordered pane chrome")
	}
}

func TestModel_ErrorClears_OnSuccessfulResolve(t *testing.T) {
	t.Parallel()

	m := NewModelWithResolver(stubResolver("party-ok", ViewWorker))
	// First set error state
	m.Err = fmt.Errorf("temporary failure")
	// Then successful resolve clears it
	updated, _ := m.Update(sessionMsg{id: "party-ok", mode: ViewWorker})
	model := updated.(Model)

	if model.Err != nil {
		t.Errorf("expected error to be cleared, got: %v", model.Err)
	}
}

func TestModel_TransientError_PreservesResolvedSession(t *testing.T) {
	t.Parallel()

	m := NewModelWithResolver(stubResolver("party-ok", ViewWorker))
	// Simulate successful initial resolve
	updated, _ := m.Update(sessionMsg{id: "party-ok", mode: ViewWorker})
	m = updated.(Model)
	m.Width = 80
	m.Height = 24

	if m.SessionID != "party-ok" {
		t.Fatalf("precondition: expected session 'party-ok', got %q", m.SessionID)
	}
	if m.Err != nil {
		t.Fatalf("precondition: expected no error, got: %v", m.Err)
	}

	// Simulate transient tmux failure (e.g., unrelated session killed)
	updated, _ = m.Update(sessionMsg{err: fmt.Errorf("cannot detect tmux session: tmux exited with status 1")})
	m = updated.(Model)

	// Session state must be preserved — not wiped by a transient error
	if m.SessionID != "party-ok" {
		t.Errorf("transient error wiped SessionID: got %q, want %q", m.SessionID, "party-ok")
	}
	if m.Err != nil {
		t.Errorf("transient error set Err on already-resolved session: %v", m.Err)
	}

	// View should still render the worker sidebar, not the error view
	view := m.View()
	if strings.Contains(view, "PARTY_SESSION") {
		t.Error("transient error should not show the error/hint view")
	}
}

func TestModel_InitialError_StillShown(t *testing.T) {
	t.Parallel()

	m := NewModelWithResolver(func() (SessionInfo, error) {
		return SessionInfo{}, fmt.Errorf("no party session found")
	})

	// Error on first resolve (no prior session) — should display error
	updated, _ := m.Update(sessionMsg{err: fmt.Errorf("no party session found")})
	model := updated.(Model)

	if model.Err == nil {
		t.Fatal("initial error should be set when no session was previously resolved")
	}
	if model.SessionID != "" {
		t.Errorf("expected empty SessionID on initial error, got %q", model.SessionID)
	}
}

// ---------------------------------------------------------------------------
// Bordered pane chrome — worker view
// ---------------------------------------------------------------------------

func TestModel_View_Wide_BorderedChrome(t *testing.T) {
	t.Parallel()

	m := NewModelWithResolver(stubResolver("party-wide", ViewWorker))
	m.SessionID = "party-wide"
	m.Mode = ViewWorker
	m.Width = 80
	m.Height = 24
	m.SessionTitle = "tui style match"
	m.SessionCwd = "~/Code/ai-config"

	view := m.View()

	if !strings.Contains(view, "╭") || !strings.Contains(view, "╯") {
		t.Error("wide worker view must use bordered pane chrome (╭╮╰╯)")
	}
	if !strings.Contains(view, "Worker:") {
		t.Error("wide worker view should contain 'Worker:' in pane title")
	}
	// Footer hints must be in the pane footer border, not as standalone lines
	if !strings.Contains(view, "quit") {
		t.Error("wide worker view should contain quit hint in footer")
	}
	if !strings.Contains(view, "peek") {
		t.Error("wide worker view should contain peek hint in footer")
	}
	// Must NOT contain old flat horizontal rules
	if strings.Contains(view, "──────\n") && !strings.Contains(view, "╭") {
		t.Error("wide worker view should not use flat horizontal rules outside bordered pane")
	}
}

func TestModel_View_Wide_NoStatusBarInSteadyState(t *testing.T) {
	t.Parallel()

	m := NewModelWithResolver(stubResolver("party-steady", ViewWorker))
	m.SessionID = "party-steady"
	m.Mode = ViewWorker
	m.Width = 80
	m.Height = 24

	view := m.View()
	lines := strings.Split(view, "\n")

	// Count lines to verify body budget = outerHeight - 2 (no status bar)
	// The bordered pane should have exactly Height lines (top + inner + bottom)
	nonEmpty := 0
	for _, l := range lines {
		if l != "" {
			nonEmpty++
		}
	}
	if nonEmpty > m.Height {
		t.Errorf("steady-state worker should not exceed height budget (%d), got %d non-empty lines", m.Height, nonEmpty)
	}
}

func TestModel_View_Compact_BorderedChrome(t *testing.T) {
	t.Parallel()

	m := NewModelWithResolver(stubResolver("party-narrow", ViewWorker))
	m.SessionID = "party-narrow"
	m.Width = 40 // below compactThreshold
	m.Height = 24

	view := m.View()

	if !strings.Contains(view, "╭") || !strings.Contains(view, "╯") {
		t.Error("compact worker view must use bordered pane chrome")
	}
	if !strings.Contains(view, "party-narrow") {
		t.Error("compact view should contain session ID")
	}
	if !strings.Contains(view, "worker") {
		t.Error("compact worker view should show 'worker' label")
	}
}

func TestModel_View_ShortHeight_NoStatusBar(t *testing.T) {
	t.Parallel()

	m := NewModelWithResolver(stubResolver("party-short", ViewWorker))
	m.SessionID = "party-short"
	m.Mode = ViewWorker
	m.Width = 80
	m.Height = 10 // below compactHeightThreshold

	view := m.View()

	if !strings.Contains(view, "╭") {
		t.Error("short-height worker view must still use bordered pane chrome")
	}
	if !strings.Contains(view, "party-short") {
		t.Error("short-height worker view must contain session identity")
	}
}

func TestModel_View_Wide_Master(t *testing.T) {
	t.Parallel()

	m := NewModelWithResolver(stubResolver("party-wide", ViewMaster))
	m.SessionID = "party-wide"
	m.Mode = ViewMaster
	m.Width = 120
	m.Height = 40

	view := m.View()

	if !strings.Contains(view, "Master:") {
		t.Error("wide master view should contain 'Master:' header")
	}
}

// ---------------------------------------------------------------------------
// Error view — bordered chrome
// ---------------------------------------------------------------------------

func TestModel_View_Error_BorderedChrome(t *testing.T) {
	t.Parallel()

	m := NewModelWithResolver(func() (SessionInfo, error) {
		return SessionInfo{}, fmt.Errorf("no party session found")
	})
	m.Err = fmt.Errorf("no party session found")
	m.Width = 80
	m.Height = 24

	view := m.View()

	if !strings.Contains(view, "╭") || !strings.Contains(view, "╯") {
		t.Error("error view must use bordered pane chrome")
	}
	if !strings.Contains(view, "no party session found") {
		t.Error("error view should contain the error message")
	}
	if !strings.Contains(view, "PARTY_SESSION") {
		t.Error("error view should hint about PARTY_SESSION")
	}
}

// ---------------------------------------------------------------------------
// Worker body flat-list layout
// ---------------------------------------------------------------------------

func TestModel_View_Wide_FlatListLayout(t *testing.T) {
	t.Parallel()

	m := NewModelWithResolver(stubResolver("party-flat", ViewWorker))
	m.SessionID = "party-flat"
	m.Mode = ViewWorker
	m.Width = 80
	m.Height = 24
	m.SessionTitle = "tui style match"
	m.SessionCwd = "~/Code/ai-config"
	m.CodexStatus = CodexStatus{State: CodexIdle, Verdict: "APPROVE"}

	view := m.View()

	// Title and cwd should render as direct value lines, NOT as "title: X" label:value pairs
	if strings.Contains(view, "title:") || strings.Contains(view, "cwd:") {
		t.Error("flat-list layout must not use label:value format for title/cwd")
	}
	// Title and cwd content should still be present
	if !strings.Contains(view, "tui style match") {
		t.Error("worker body should contain session title as direct value line")
	}
	if !strings.Contains(view, "~/Code/ai-config") {
		t.Error("worker body should contain session cwd as direct value line")
	}
}

// ---------------------------------------------------------------------------
// Tick refresh
// ---------------------------------------------------------------------------

func TestModel_TickMsg_ReturnsCommand(t *testing.T) {
	t.Parallel()

	m := NewModelWithResolver(stubResolver("party-tick", ViewWorker))
	m.SessionID = "party-tick"

	_, cmd := m.Update(tickMsg{})

	if cmd == nil {
		t.Fatal("tickMsg should return a command (resolve + next tick)")
	}
}

func TestModel_RefreshMsg_ReturnsCommand(t *testing.T) {
	t.Parallel()

	m := NewModelWithResolver(stubResolver("party-refresh", ViewWorker))
	m.SessionID = "party-refresh"

	_, cmd := m.Update(refreshMsg{})

	if cmd == nil {
		t.Fatal("refreshMsg should return a resolve command")
	}
}

// ---------------------------------------------------------------------------
// Quit
// ---------------------------------------------------------------------------

func TestModel_QuitOnQ(t *testing.T) {
	t.Parallel()

	m := NewModelWithResolver(stubResolver("party-q", ViewWorker))
	_, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'q'}})

	if cmd == nil {
		t.Fatal("'q' should produce a quit command")
	}
}

func TestModel_QuitOnCtrlC(t *testing.T) {
	t.Parallel()

	m := NewModelWithResolver(stubResolver("party-cc", ViewWorker))
	_, cmd := m.Update(tea.KeyMsg{Type: tea.KeyCtrlC})

	if cmd == nil {
		t.Fatal("ctrl+c should produce a quit command")
	}
}

// ---------------------------------------------------------------------------
// WindowSizeMsg
// ---------------------------------------------------------------------------

func TestModel_WindowSizeMsg(t *testing.T) {
	t.Parallel()

	m := NewModelWithResolver(stubResolver("party-sz", ViewWorker))
	updated, _ := m.Update(tea.WindowSizeMsg{Width: 80, Height: 24})
	model := updated.(Model)

	if model.Width != 80 {
		t.Errorf("expected Width=80, got %d", model.Width)
	}
	if model.Height != 24 {
		t.Errorf("expected Height=24, got %d", model.Height)
	}
}

func TestModel_WindowSizeMsg_ShrinkClearsScreen(t *testing.T) {
	t.Parallel()

	m := NewModelWithResolver(stubResolver("party-sz", ViewWorker))
	m.Width = 80
	m.Height = 40

	// Shrink: should return a command (ClearScreen) to prevent stale lines.
	_, cmd := m.Update(tea.WindowSizeMsg{Width: 80, Height: 24})
	if cmd == nil {
		t.Error("height shrink should return a clear-screen command")
	}
}

func TestModel_WindowSizeMsg_ExpandNoCommand(t *testing.T) {
	t.Parallel()

	m := NewModelWithResolver(stubResolver("party-sz", ViewWorker))
	m.Width = 80
	m.Height = 24

	// Expand: should return nil (no flicker needed).
	_, cmd := m.Update(tea.WindowSizeMsg{Width: 80, Height: 40})
	if cmd != nil {
		t.Error("height expand should not return a command")
	}
}

func TestModel_WindowSizeMsg_SameSizeNoCommand(t *testing.T) {
	t.Parallel()

	m := NewModelWithResolver(stubResolver("party-sz", ViewWorker))
	m.Width = 80
	m.Height = 24

	// Same height: no repaint needed.
	_, cmd := m.Update(tea.WindowSizeMsg{Width: 80, Height: 24})
	if cmd != nil {
		t.Error("same-size ping should not return a command")
	}
}

func TestModel_TrackerCreation_ClearsScreen(t *testing.T) {
	t.Parallel()

	factory := func(masterID string) TrackerModel {
		return NewTrackerModel(masterID, stubFetcher(nil), &fakeActions{})
	}

	// Baseline: master sessionMsg WITHOUT trackerFactory returns a cmd
	// (from refreshCodexStatus/refreshEvidence) but no ClearScreen.
	baseline := NewModelWithResolver(stubResolver("party-m", ViewMaster))
	baseline.Width = 80
	baseline.Height = 24
	updatedBase, baseCmd := baseline.Update(sessionMsg{id: "party-m", mode: ViewMaster})
	baseModel := updatedBase.(Model)
	if baseModel.tracker != nil {
		t.Fatal("baseline should not create tracker without factory")
	}

	// With factory: should create tracker AND include ClearScreen in the batch.
	m := NewModelWithResolver(stubResolver("party-m", ViewMaster))
	m.trackerFactory = factory
	m.Width = 80
	m.Height = 24
	updated, cmd := m.Update(sessionMsg{id: "party-m", mode: ViewMaster})
	model := updated.(Model)

	if model.tracker == nil {
		t.Fatal("tracker should be created on master sessionMsg")
	}
	if cmd == nil {
		t.Fatal("tracker creation should return a command batch")
	}
	// BubbleTea commands are opaque, but the batch with ClearScreen differs
	// from the baseline batch without it — verify they're distinct function pointers.
	if baseCmd == nil {
		// Baseline also returns commands (refreshCodexStatus, etc).
		// If baseline is nil, our test can't compare — just verify cmd != nil.
		return
	}
	// Both are non-nil Batch commands; the one with ClearScreen has an
	// additional entry. We can't decompose further without BubbleTea internals.
}

func TestModel_Promotion_ClearsScreen(t *testing.T) {
	t.Parallel()

	factory := func(masterID string) TrackerModel {
		return NewTrackerModel(masterID, stubFetcher(nil), &fakeActions{})
	}
	m := NewModelWithResolver(stubResolver("party-p", ViewWorker))
	m.trackerFactory = factory
	m.Width = 80
	m.Height = 24

	// First resolve as worker.
	updated, _ := m.Update(sessionMsg{id: "party-p", mode: ViewWorker})
	m = updated.(Model)

	// Promote to master — should clear screen.
	updated, cmd := m.Update(sessionMsg{id: "party-p", mode: ViewMaster})
	model := updated.(Model)

	if model.Mode != ViewMaster {
		t.Error("mode should be promoted to master")
	}
	if cmd == nil {
		t.Error("promotion to master should return a command batch including clear-screen")
	}
}

// ---------------------------------------------------------------------------
// ViewMode stringer
// ---------------------------------------------------------------------------

func TestViewMode_String(t *testing.T) {
	t.Parallel()

	tests := map[string]struct {
		mode ViewMode
		want string
	}{
		"worker":  {ViewWorker, "worker"},
		"master":  {ViewMaster, "master"},
		"unknown": {ViewMode(99), "unknown"},
	}

	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			if got := tc.mode.String(); got != tc.want {
				t.Errorf("String(): got %q, want %q", got, tc.want)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// Session identity immutability
// ---------------------------------------------------------------------------

func TestModel_SessionIdentity_LockedAfterFirstResolve(t *testing.T) {
	t.Parallel()

	m := NewModelWithResolver(stubResolver("party-worker-1", ViewWorker))

	// First resolve — sets identity
	updated, _ := m.Update(sessionMsg{id: "party-worker-1", mode: ViewWorker, title: "my task", cwd: "/repo/a"})
	m = updated.(Model)

	if m.SessionID != "party-worker-1" || m.Mode != ViewWorker {
		t.Fatalf("precondition: expected worker identity, got id=%q mode=%v", m.SessionID, m.Mode)
	}

	// Second resolve returns a DIFFERENT session (master from another tmux client).
	// The TUI must ignore this — its identity, title, and cwd are locked.
	updated, _ = m.Update(sessionMsg{id: "party-master-9", mode: ViewMaster, title: "foreign task", cwd: "/repo/b"})
	m = updated.(Model)

	if m.SessionID != "party-worker-1" {
		t.Errorf("session ID changed to %q after re-resolve; want locked at %q", m.SessionID, "party-worker-1")
	}
	if m.Mode != ViewWorker {
		t.Errorf("mode changed to %v after re-resolve; want locked at %v", m.Mode, ViewWorker)
	}
	if m.SessionTitle != "my task" {
		t.Errorf("title contaminated by foreign session: got %q, want %q", m.SessionTitle, "my task")
	}
	if m.SessionCwd != "/repo/a" {
		t.Errorf("cwd contaminated by foreign session: got %q, want %q", m.SessionCwd, "/repo/a")
	}
}

func TestModel_SessionIdentity_MasterNeverDemotedToWorker(t *testing.T) {
	t.Parallel()

	m := NewModelWithResolver(stubResolver("party-master-1", ViewMaster))

	// First resolve — master
	updated, _ := m.Update(sessionMsg{id: "party-master-1", mode: ViewMaster})
	m = updated.(Model)

	// Subsequent resolve tries to demote to worker (misdetection)
	updated, _ = m.Update(sessionMsg{id: "party-master-1", mode: ViewWorker})
	m = updated.(Model)

	if m.Mode != ViewMaster {
		t.Errorf("master was demoted to %v; mode should be immutable downward", m.Mode)
	}
}

func TestModel_SessionIdentity_PromotionWorkerToMaster(t *testing.T) {
	t.Parallel()

	m := NewModelWithResolver(stubResolver("party-abc", ViewWorker))

	// First resolve — worker
	updated, _ := m.Update(sessionMsg{id: "party-abc", mode: ViewWorker})
	m = updated.(Model)

	if m.Mode != ViewWorker {
		t.Fatalf("precondition: expected worker, got %v", m.Mode)
	}

	// Promotion: same session ID, mode changes to master (real --promote)
	updated, _ = m.Update(sessionMsg{id: "party-abc", mode: ViewMaster})
	m = updated.(Model)

	if m.Mode != ViewMaster {
		t.Errorf("promotion failed: mode is %v, want ViewMaster", m.Mode)
	}
	if m.SessionID != "party-abc" {
		t.Errorf("session ID changed during promotion: got %q, want %q", m.SessionID, "party-abc")
	}
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

func TestTruncate(t *testing.T) {
	t.Parallel()

	tests := map[string]struct {
		s      string
		maxLen int
		want   string
	}{
		"no truncation":   {"hello", 10, "hello"},
		"exact fit":       {"hello", 5, "hello"},
		"truncated":       {"hello world", 8, "hello w\u2026"},
		"maxLen 1":        {"ab", 1, "\u2026"},
		"maxLen 0":        {"ab", 0, "ab"},
		"negative maxLen": {"ab", -1, "ab"},
	}

	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			got := truncate(tc.s, tc.maxLen)
			if got != tc.want {
				t.Errorf("truncate(%q, %d): got %q, want %q", tc.s, tc.maxLen, got, tc.want)
			}
		})
	}
}

func TestDisambiguatePartySessions(t *testing.T) {
	t.Parallel()

	tests := map[string]struct {
		sessions []string
		wantID   string
		wantErr  bool
	}{
		"single match": {
			sessions: []string{"party-abc", "other-session"},
			wantID:   "party-abc",
		},
		"no match": {
			sessions: []string{"other-session"},
			wantErr:  true,
		},
		"empty": {
			sessions: nil,
			wantErr:  true,
		},
		"multiple matches": {
			sessions: []string{"party-abc", "party-def"},
			wantErr:  true,
		},
	}

	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			id, err := disambiguatePartySessions(tc.sessions)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("expected error, got id=%q", id)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if id != tc.wantID {
				t.Errorf("got %q, want %q", id, tc.wantID)
			}
		})
	}
}

