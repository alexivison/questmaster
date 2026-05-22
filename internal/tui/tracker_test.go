package tui

import (
	"context"
	"fmt"
	"io"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
	"github.com/muesli/termenv"
)

type fakeActions struct {
	attachCalls    []string
	continueCalls  []string
	continueErr    error
	relayCalls     []relayCall
	broadcastCalls []broadcastCall
	spawnCalls     []spawnCall
	deleteCalls    []deleteCall
	manifestJSON   map[string]string
	err            error
}

type relayCall struct {
	workerID string
	message  string
}

type broadcastCall struct {
	masterID string
	message  string
}

type spawnCall struct {
	masterID string
	title    string
}

type deleteCall struct {
	ownerID  string
	targetID string
}

func (f *fakeActions) Attach(_ context.Context, _, targetID string) error {
	f.attachCalls = append(f.attachCalls, targetID)
	return f.err
}

func (f *fakeActions) Continue(_ context.Context, sessionID string) error {
	f.continueCalls = append(f.continueCalls, sessionID)
	return f.continueErr
}

func (f *fakeActions) Relay(_ context.Context, workerID, message string) error {
	f.relayCalls = append(f.relayCalls, relayCall{workerID: workerID, message: message})
	return f.err
}

func (f *fakeActions) Broadcast(_ context.Context, masterID, message string) error {
	f.broadcastCalls = append(f.broadcastCalls, broadcastCall{masterID: masterID, message: message})
	return f.err
}

func (f *fakeActions) Spawn(_ context.Context, masterID, title string) error {
	f.spawnCalls = append(f.spawnCalls, spawnCall{masterID: masterID, title: title})
	return f.err
}

func (f *fakeActions) Delete(_ context.Context, ownerID, workerID string) error {
	f.deleteCalls = append(f.deleteCalls, deleteCall{ownerID: ownerID, targetID: workerID})
	return f.err
}

func (f *fakeActions) ManifestJSON(sessionID string) (string, error) {
	if f.manifestJSON == nil {
		return "", fmt.Errorf("manifest not found")
	}
	return f.manifestJSON[sessionID], nil
}

func snapshotFetcher(snapshot TrackerSnapshot) SessionFetcher {
	return func(SessionInfo) (TrackerSnapshot, error) {
		return snapshot, nil
	}
}

func newTestTracker(current SessionInfo, snapshot TrackerSnapshot, actions TrackerActions) TrackerModel {
	tm := NewTrackerModel(current, snapshotFetcher(snapshot), actions)
	tm.width = 80
	// Tall enough that boxed session cards (≈7 lines each) for multiple
	// sessions fit without pane-clipping elided lines.
	tm.height = 80
	tm.applySnapshot(snapshot)
	return tm
}

func keyMsg(r rune) tea.KeyMsg {
	return tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}}
}

func benchmarkTrackerSnapshot() TrackerSnapshot {
	sessions := []SessionRow{
		{
			ID:           "party-master",
			Title:        "orchestrator",
			Cwd:          "/tmp/orchestrator",
			Status:       "active",
			SessionType:  "master",
			PrimaryAgent: "claude",
			State:        "working",
			IsCurrent:    true,
			Snippet:      "⏺ coordinating workers",
		},
	}
	for i := range 12 {
		sessions = append(sessions, SessionRow{
			ID:           fmt.Sprintf("party-worker-%02d", i),
			Title:        fmt.Sprintf("worker-%02d", i),
			Cwd:          fmt.Sprintf("/tmp/worker-%02d", i),
			Status:       "active",
			SessionType:  "worker",
			ParentID:     "party-master",
			PrimaryAgent: "codex",
			State:        map[bool]string{true: "working", false: "idle"}[i%2 == 0],
			Snippet:      fmt.Sprintf("• worker %02d status update", i),
		})
	}
	for i := range 10 {
		sessions = append(sessions, SessionRow{
			ID:           fmt.Sprintf("party-standalone-%02d", i),
			Title:        fmt.Sprintf("standalone-%02d", i),
			Cwd:          fmt.Sprintf("/tmp/standalone-%02d", i),
			Status:       "active",
			SessionType:  "standalone",
			PrimaryAgent: "claude",
			Snippet:      fmt.Sprintf("⏺ standalone %02d output", i),
		})
	}

	return TrackerSnapshot{
		Sessions: sessions,
		Current: CurrentSessionDetail{
			Title:       "orchestrator",
			SessionType: "master",
		},
	}
}

func TestTrackerViewNoSessions(t *testing.T) {
	t.Parallel()

	tm := newTestTracker(SessionInfo{ID: "party-solo"}, TrackerSnapshot{}, &fakeActions{})
	view := tm.View()

	if !strings.Contains(view, "No sessions") {
		t.Fatalf("expected empty-state message, got:\n%s", view)
	}
}

func TestTrackerViewShowsHierarchy(t *testing.T) {
	t.Parallel()

	snapshot := TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "party-1230", Title: "Project Alpha", Cwd: "/tmp/project-alpha", Status: "active", SessionType: "master", WorkerCount: 2, PrimaryAgent: "claude", IsCurrent: true, State: "idle"},
			{ID: "party-1231", Title: "fix-auth", Cwd: "/tmp/fix-auth", Status: "active", SessionType: "worker", ParentID: "party-1230", PrimaryAgent: "claude", Snippet: "❯ make test\n⏺ running tests", State: "idle"},
			{ID: "party-1232", Title: "dark-mode", Cwd: "/tmp/dark-mode", Status: "active", SessionType: "worker", ParentID: "party-1230", PrimaryAgent: "codex", HasCompanion: true, Snippet: "• review queued", State: "idle"},
			{ID: "party-1236", Title: "solo task", Cwd: "/tmp/solo", Status: "active", SessionType: "standalone", PrimaryAgent: "codex", Snippet: "❯ npm test\n⎿ 42 passed", State: "idle"},
			{ID: "party-1237", Title: "no-agent", Cwd: "/tmp/no-agent", Status: "active", SessionType: "standalone", State: "idle"},
		},
		Current: CurrentSessionDetail{
			Title:       "Project Alpha",
			SessionType: "master",
		},
	}

	tm := newTestTracker(SessionInfo{ID: "party-1230", SessionType: "master"}, snapshot, &fakeActions{})
	view := tm.View()

	for _, needle := range []string{"Project Alpha", "fix-auth", "dark-mode", "solo task"} {
		if !strings.Contains(view, needle) {
			t.Fatalf("expected %q in view, got:\n%s", needle, view)
		}
	}
	for _, needle := range []string{"\U000f06c4 Project Alpha", "\uf44f dark-mode", "\uf44f solo task"} {
		if !strings.Contains(view, needle) {
			t.Fatalf("expected title icon %q in view, got:\n%s", needle, view)
		}
	}
	// Sessions without a recognized agent fall back to '\u25cb' as the activity glyph.
	if !strings.Contains(view, "\u25cb no-agent") {
		t.Fatalf("expected \u25cb fallback glyph for agentless session, got:\n%s", view)
	}
	for _, needle := range []string{"party-1231", "/tmp/fix-auth"} {
		if !strings.Contains(view, needle) {
			t.Fatalf("expected secondary row detail %q in view, got:\n%s", needle, view)
		}
	}
	for _, needle := range []string{"running tests", "review queued", "42 passed"} {
		if !strings.Contains(view, needle) {
			t.Fatalf("expected snippet %q in view, got:\n%s", needle, view)
		}
	}
	if strings.Contains(view, "❯ make test") || strings.Contains(view, "❯ npm test") {
		t.Fatalf("did not expect ❯ user-prompt lines in snippet view, got:\n%s", view)
	}
	for _, marker := range []string{"⏺", "•", "⎿"} {
		if strings.Contains(view, marker) {
			t.Fatalf("did not expect agent marker %q in snippet view (should be stripped), got:\n%s", marker, view)
		}
	}
	if !strings.Contains(view, "⚔ party-1230") {
		t.Fatalf("expected ⚔ icon on master metadata row, got:\n%s", view)
	}
	if !strings.Contains(view, "⚒ party-1231") {
		t.Fatalf("expected ⚒ icon on worker metadata row, got:\n%s", view)
	}
	if !strings.Contains(view, "✠ party-1236") {
		t.Fatalf("expected ✠ icon on standalone metadata row, got:\n%s", view)
	}
	if !strings.Contains(view, "┃") {
		t.Fatalf("expected worker tree connector in view, got:\n%s", view)
	}
	if !strings.Contains(view, "|") {
		t.Fatalf("expected snippet bar in view, got:\n%s", view)
	}
}

func TestTrackerViewOmitsCurrentSessionDetailBlock(t *testing.T) {
	t.Parallel()

	snapshot := TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "party-2001", Title: "bugfix", Status: "active", SessionType: "worker", ParentID: "party-master", PrimaryAgent: "codex", Snippet: "❯ fix lint", IsCurrent: true},
		},
		Current: CurrentSessionDetail{
			Title:       "bugfix",
			SessionType: "worker",
		},
	}

	tm := newTestTracker(SessionInfo{ID: "party-2001", SessionType: "worker"}, snapshot, &fakeActions{})
	view := tm.View()

	if strings.Contains(view, "companion:") {
		t.Fatalf("did not expect companion detail block, got:\n%s", view)
	}
	if strings.Contains(view, "evidence:") {
		t.Fatalf("did not expect evidence detail block, got:\n%s", view)
	}
	if got := strings.Count(view, strings.Repeat("─", tm.width)); got != 1 {
		t.Fatalf("expected only the header divider with no detail divider, got %d\n%s", got, view)
	}
	if strings.Contains(view, "1 sessions") || strings.Contains(view, "j/k") {
		t.Fatalf("did not expect the legacy tracker footer, got:\n%s", view)
	}
}

func TestTrackerViewShowsPartyTitleInHeader(t *testing.T) {
	lipgloss.SetColorProfile(termenv.TrueColor)
	t.Cleanup(func() {
		lipgloss.SetColorProfile(termenv.Ascii)
	})

	snapshot := TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "party-master", Title: "Project Alpha", Status: "active", SessionType: "master", PrimaryAgent: "claude", IsCurrent: true},
		},
		Current: CurrentSessionDetail{
			Title:       "Project Alpha",
			SessionType: "master",
		},
	}

	tm := newTestTracker(SessionInfo{ID: "party-master", SessionType: "master"}, snapshot, &fakeActions{})
	view := tm.View()

	expectedTitle := renderTrackerANSI(paneTitleStyle, "⚔ Project Alpha (party-master)")
	if !strings.Contains(view, expectedTitle) {
		t.Fatalf("expected titled tracker header with master role glyph, got:\n%s", view)
	}
}

func TestTrackerViewUsesWorkerChromeForWorkerHeader(t *testing.T) {
	lipgloss.SetColorProfile(termenv.TrueColor)
	t.Cleanup(func() {
		lipgloss.SetColorProfile(termenv.Ascii)
	})

	snapshot := TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "party-master", Title: "Project Alpha", Status: "active", SessionType: "master", PrimaryAgent: "claude"},
			{ID: "party-worker", Title: "Investigate", Status: "active", SessionType: "worker", ParentID: "party-master", PrimaryAgent: "codex", IsCurrent: true},
		},
		Current: CurrentSessionDetail{
			Title:       "Investigate",
			SessionType: "worker",
		},
	}

	tm := newTestTracker(SessionInfo{ID: "party-worker", SessionType: "worker"}, snapshot, &fakeActions{})
	view := tm.View()

	expectedTitle := renderTrackerANSI(paneTitleStyle, "⚒ Investigate (party-worker)")
	if !strings.Contains(view, expectedTitle) {
		t.Fatalf("expected worker tracker header with worker role glyph, got:\n%s", view)
	}

	// Pane title must no longer carry any agent-color foreground.
	codexTinted := renderTrackerANSI(paneTitleStyle.Foreground(agentIdentityStyle("codex").GetForeground()), "⚒ Investigate (party-worker)")
	if strings.Contains(view, codexTinted) {
		t.Fatalf("expected pane title to use default foreground, not agent color, got:\n%s", view)
	}
}

func TestTrackerViewFallsBackToSessionHeaderWhenTitleMissing(t *testing.T) {
	lipgloss.SetColorProfile(termenv.TrueColor)
	t.Cleanup(func() {
		lipgloss.SetColorProfile(termenv.Ascii)
	})

	snapshot := TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "party-current", Status: "active", SessionType: "standalone", PrimaryAgent: "pi", IsCurrent: true},
		},
		Current: CurrentSessionDetail{
			SessionType: "standalone",
		},
	}

	tm := newTestTracker(SessionInfo{ID: "party-current", SessionType: "standalone"}, snapshot, &fakeActions{})
	view := tm.View()

	expectedTitle := renderTrackerANSI(paneTitleStyle, "✠ party-current")
	if !strings.Contains(view, expectedTitle) {
		t.Fatalf("expected session ID fallback header with standalone role glyph, got:\n%s", view)
	}
	if strings.Contains(view, "Standalone:") {
		t.Fatalf("did not expect legacy role-badge header fallback, got:\n%s", view)
	}
	if strings.Contains(view, "Party Tracker —") {
		t.Fatalf("did not expect titled tracker header without a title, got:\n%s", view)
	}
}

// TestTrackerPaneTitleUsesRoleGlyph pins the pane-title header to the
// new role-glyph + default-foreground rendering. Each session type
// (master / worker / standalone) gets its adventuring-party glyph; agent
// color must not leak in.
func TestTrackerPaneTitleUsesRoleGlyph(t *testing.T) {
	cases := []struct {
		sessionType string
		wantGlyph   string
	}{
		{sessionType: "master", wantGlyph: "⚔"},
		{sessionType: "worker", wantGlyph: "⚒"},
		{sessionType: "standalone", wantGlyph: "✠"},
	}
	for _, tc := range cases {
		t.Run(tc.sessionType, func(t *testing.T) {
			lipgloss.SetColorProfile(termenv.TrueColor)
			t.Cleanup(func() { lipgloss.SetColorProfile(termenv.Ascii) })

			snapshot := TrackerSnapshot{
				Sessions: []SessionRow{
					{ID: "party-x", Title: "Demo", Status: "active", SessionType: tc.sessionType, PrimaryAgent: "claude", IsCurrent: true},
				},
				Current: CurrentSessionDetail{Title: "Demo", SessionType: tc.sessionType},
			}
			tm := newTestTracker(SessionInfo{ID: "party-x", SessionType: tc.sessionType}, snapshot, &fakeActions{})
			view := tm.View()

			expectedTitle := renderTrackerANSI(paneTitleStyle, tc.wantGlyph+" Demo (party-x)")
			if !strings.Contains(view, expectedTitle) {
				t.Fatalf("session type %q: expected pane title with glyph %q, got:\n%s", tc.sessionType, tc.wantGlyph, view)
			}

			tinted := renderTrackerANSI(paneTitleStyle.Foreground(agentIdentityStyle("claude").GetForeground()), tc.wantGlyph+" Demo (party-x)")
			if strings.Contains(view, tinted) {
				t.Fatalf("session type %q: pane title must not be tinted with the agent color, got:\n%s", tc.sessionType, view)
			}
		})
	}
}

func TestTrackerViewShowsErrorInStatusBarWithoutFooter(t *testing.T) {
	t.Parallel()

	tm := newTestTracker(SessionInfo{ID: "party-master", SessionType: "master"}, TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "party-master", Title: "orchestrator", Status: "active", SessionType: "master", PrimaryAgent: "claude", IsCurrent: true},
		},
		Current: CurrentSessionDetail{
			Title:       "orchestrator",
			SessionType: "master",
		},
	}, &fakeActions{})
	tm.lastErr = fmt.Errorf("relay failed")
	view := tm.View()

	if !strings.Contains(view, "relay failed") {
		t.Fatalf("expected error in status bar, got:\n%s", view)
	}
	if strings.Contains(view, "error: relay failed") {
		t.Fatalf("did not expect legacy footer-style error prefix, got:\n%s", view)
	}
}

func TestTrackerViewFillsPaneHeight(t *testing.T) {
	t.Parallel()

	tm := newTestTracker(SessionInfo{ID: "party-current"}, TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "party-current", Title: "current", Status: "active", SessionType: "standalone", IsCurrent: true},
			{ID: "party-other", Title: "other", Status: "active", SessionType: "standalone"},
		},
	}, &fakeActions{})
	tm.width = 70
	tm.height = 12

	view := tm.View()
	if got := len(strings.Split(view, "\n")); got != tm.height {
		t.Fatalf("view line count = %d, want %d\n%s", got, tm.height, view)
	}
}

func TestTrackerRenderSessionRowSelectedRowTintCoversStyledLines(t *testing.T) {
	lipgloss.SetColorProfile(termenv.TrueColor)
	t.Cleanup(func() {
		lipgloss.SetColorProfile(termenv.Ascii)
	})

	row := SessionRow{
		ID:           "party-worker",
		Title:        "investigate",
		Cwd:          "/tmp/project",
		Status:       "active",
		SessionType:  "worker",
		ParentID:     "party-master",
		PrimaryAgent: "claude",
		State:        "working",
		Snippet:      "⏺ running tests",
	}
	tm := TrackerModel{
		cursor:   0,
		blinkOn:  true,
		sessions: []SessionRow{row, {ID: "party-sibling", SessionType: "worker", ParentID: "party-master"}},
	}

	const innerW = 48
	got := tm.renderSessionRow(row, 0, innerW)
	lines := strings.Split(got, "\n")
	if len(lines) != 3 {
		t.Fatalf("selected row line count = %d, want 3\n%s", len(lines), got)
	}

	selectedTree := renderTrackerANSI(selectedRowStyle.Inherit(treeGutterStyle), "┣━ ")
	selectedDot := renderTrackerANSI(selectedRowStyle.Inherit(agentIdentityStyle("claude")), "\U000f06c4")
	selectedGap := renderTrackerANSI(selectedRowStyle, " ")
	selectedSnippetBar := renderTrackerANSI(selectedRowStyle.Inherit(snippetBarStyle), "|")
	selectedMeta := renderTrackerANSI(selectedRowStyle.Inherit(metaTextStyle), "⚒ "+row.ID)

	for i, line := range lines {
		if gotW := ansi.StringWidth(line); gotW != innerW {
			t.Fatalf("line %d width = %d, want %d\n%q", i, gotW, innerW, line)
		}
	}
	if !strings.Contains(lines[0], selectedTree) {
		t.Fatalf("selected title line missing tree gutter tint\n%q", lines[0])
	}
	if !strings.Contains(lines[0], selectedDot+selectedGap) {
		t.Fatalf("selected title line missing tinted activity icon/gap\n%q", lines[0])
	}
	if !strings.Contains(lines[1], selectedSnippetBar) {
		t.Fatalf("selected snippet line missing tinted snippet bar\n%q", lines[1])
	}
	if !strings.Contains(lines[2], selectedMeta) {
		t.Fatalf("selected meta line missing tinted metadata\n%q", lines[2])
	}
}

func TestTrackerRenderSessionRowKeepsFullLayoutAtNarrowWidth(t *testing.T) {
	lipgloss.SetColorProfile(termenv.TrueColor)
	t.Cleanup(func() {
		lipgloss.SetColorProfile(termenv.Ascii)
	})

	row := SessionRow{
		ID:           "party-worker",
		Title:        "investigate",
		Cwd:          "/tmp/project",
		Status:       "active",
		SessionType:  "worker",
		ParentID:     "party-master",
		PrimaryAgent: "claude",
		State:        "working",
		Snippet:      "⏺ running tests with a long snippet",
	}
	tm := TrackerModel{
		cursor:   0,
		blinkOn:  true,
		sessions: []SessionRow{row, {ID: "party-sibling", SessionType: "worker", ParentID: "party-master"}},
	}

	const innerW = 28
	got := tm.renderSessionRow(row, 0, innerW)
	lines := strings.Split(got, "\n")
	if len(lines) != 3 {
		t.Fatalf("selected row line count = %d, want 3\n%s", len(lines), got)
	}

	selectedSnippetBar := renderTrackerANSI(selectedRowStyle.Inherit(snippetBarStyle), "|")
	for i, line := range lines {
		if gotW := ansi.StringWidth(line); gotW != innerW {
			t.Fatalf("line %d width = %d, want %d\n%q", i, gotW, innerW, line)
		}
	}
	if !strings.Contains(lines[1], selectedSnippetBar) {
		t.Fatalf("selected snippet line missing tinted snippet bar\n%q", lines[1])
	}
	if !strings.Contains(lines[2], "⚒") {
		t.Fatalf("selected narrow row missing metadata line\n%q", lines[2])
	}
}

func TestTrackerUpdateEnterAttachesActiveSession(t *testing.T) {
	t.Parallel()

	actions := &fakeActions{}
	tm := newTestTracker(SessionInfo{ID: "party-current"}, TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "party-current", Title: "current", Status: "active", SessionType: "standalone", IsCurrent: true},
			{ID: "party-target", Title: "target", Status: "active", SessionType: "standalone"},
		},
	}, actions)
	tm.cursor = 1

	tm, _ = tm.Update(tea.KeyMsg{Type: tea.KeyEnter})

	if len(actions.attachCalls) != 1 || actions.attachCalls[0] != "party-target" {
		t.Fatalf("expected attach to selected active session, got %#v", actions.attachCalls)
	}
	if len(actions.continueCalls) != 0 {
		t.Fatalf("expected no continue calls for active row, got %#v", actions.continueCalls)
	}
}

func TestTrackerUpdateEnterResumesStoppedSession(t *testing.T) {
	t.Parallel()

	actions := &fakeActions{}
	tm := newTestTracker(SessionInfo{ID: "party-current"}, TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "party-current", Title: "current", Status: "active", SessionType: "standalone", IsCurrent: true},
			{ID: "party-stopped", Title: "stopped", Status: "stopped", SessionType: "standalone"},
		},
	}, actions)
	tm.cursor = 1

	tm, _ = tm.Update(tea.KeyMsg{Type: tea.KeyEnter})

	if len(actions.continueCalls) != 1 || actions.continueCalls[0] != "party-stopped" {
		t.Fatalf("expected continue on stopped row, got %#v", actions.continueCalls)
	}
	if len(actions.attachCalls) != 0 {
		t.Fatalf("expected no attach calls for stopped row, got %#v", actions.attachCalls)
	}
	if tm.lastErr != nil {
		t.Fatalf("expected no error on successful continue, got %v", tm.lastErr)
	}
}

func TestTrackerUpdateEnterContinueErrorSurfaces(t *testing.T) {
	t.Parallel()

	wantErr := fmt.Errorf("boom")
	actions := &fakeActions{continueErr: wantErr}
	tm := newTestTracker(SessionInfo{ID: "party-current"}, TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "party-current", Title: "current", Status: "active", SessionType: "standalone", IsCurrent: true},
			{ID: "party-stopped", Title: "stopped", Status: "stopped", SessionType: "standalone"},
		},
	}, actions)
	tm.cursor = 1

	tm, _ = tm.Update(tea.KeyMsg{Type: tea.KeyEnter})

	if tm.lastErr != wantErr {
		t.Fatalf("expected continue error to surface in lastErr, got %v", tm.lastErr)
	}
}

func TestTrackerUpdateRelayOnManagedWorker(t *testing.T) {
	t.Parallel()

	actions := &fakeActions{}
	tm := newTestTracker(SessionInfo{ID: "party-master"}, TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "party-master", Title: "master", Status: "active", SessionType: "master", IsCurrent: true},
			{ID: "party-worker", Title: "worker", Status: "active", SessionType: "worker", ParentID: "party-master"},
		},
		Current: CurrentSessionDetail{SessionType: "master"},
	}, actions)
	tm.cursor = 1

	tm, _ = tm.Update(keyMsg('r'))
	if tm.mode != trackerModeRelay {
		t.Fatalf("expected relay mode, got %v", tm.mode)
	}

	for _, r := range "investigate" {
		tm, _ = tm.Update(keyMsg(r))
	}
	tm, _ = tm.Update(tea.KeyMsg{Type: tea.KeyEnter})

	if len(actions.relayCalls) != 1 {
		t.Fatalf("expected one relay call, got %#v", actions.relayCalls)
	}
	if actions.relayCalls[0].workerID != "party-worker" || actions.relayCalls[0].message != "investigate" {
		t.Fatalf("unexpected relay call: %#v", actions.relayCalls[0])
	}
}

func TestTrackerRelayTypingReusesCachedSessionPane(t *testing.T) {
	t.Parallel()

	tm := newTestTracker(
		SessionInfo{ID: "party-master", SessionType: "master"},
		benchmarkTrackerSnapshot(),
		&fakeActions{},
	)
	tm.cursor = 1

	tm, _ = tm.Update(keyMsg('r'))
	if tm.mode != trackerModeRelay {
		t.Fatalf("expected relay mode, got %v", tm.mode)
	}
	if !tm.inputFrameCache.valid {
		t.Fatal("expected relay mode to pre-render the non-composer frame")
	}

	var rowRenders int
	tm.testHooks.renderSessionRow = func() { rowRenders++ }

	tm, _ = tm.Update(keyMsg('x'))
	view := tm.View()

	if !strings.Contains(view, "relay>") {
		t.Fatalf("expected relay composer in view, got:\n%s", view)
	}
	if rowRenders != 0 {
		t.Fatalf("expected cached session rows during typing, got %d renders", rowRenders)
	}
}

func TestTrackerUpdateBroadcastOnCurrentMaster(t *testing.T) {
	t.Parallel()

	actions := &fakeActions{}
	tm := newTestTracker(SessionInfo{ID: "party-master"}, TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "party-master", Title: "master", Status: "active", SessionType: "master", IsCurrent: true},
			{ID: "party-worker", Title: "worker", Status: "active", SessionType: "worker", ParentID: "party-master"},
		},
		Current: CurrentSessionDetail{SessionType: "master"},
	}, actions)

	tm, _ = tm.Update(keyMsg('b'))
	if tm.mode != trackerModeBroadcast {
		t.Fatalf("expected broadcast mode, got %v", tm.mode)
	}

	for _, r := range "take stock" {
		tm, _ = tm.Update(keyMsg(r))
	}
	tm, _ = tm.Update(tea.KeyMsg{Type: tea.KeyEnter})

	if len(actions.broadcastCalls) != 1 {
		t.Fatalf("expected one broadcast call, got %#v", actions.broadcastCalls)
	}
	if actions.broadcastCalls[0] != (broadcastCall{masterID: "party-master", message: "take stock"}) {
		t.Fatalf("unexpected broadcast call: %#v", actions.broadcastCalls[0])
	}
}

func TestTrackerUpdateRelayToActiveNonCurrentSessionFromNonMaster(t *testing.T) {
	t.Parallel()

	actions := &fakeActions{}
	tm := newTestTracker(SessionInfo{ID: "party-worker", SessionType: "worker"}, TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "party-master", Title: "master", Status: "active", SessionType: "master"},
			{ID: "party-other-worker", Title: "sibling", Status: "active", SessionType: "worker", ParentID: "party-master"},
			{ID: "party-worker", Title: "current", Status: "active", SessionType: "worker", ParentID: "party-master", IsCurrent: true},
		},
	}, actions)
	tm.cursor = 1

	tm, _ = tm.Update(keyMsg('r'))
	if tm.mode != trackerModeRelay {
		t.Fatalf("expected relay mode, got %v", tm.mode)
	}
	if tm.relayTargetID != "party-other-worker" {
		t.Fatalf("expected relay target party-other-worker, got %q", tm.relayTargetID)
	}

	for _, r := range "ping" {
		tm, _ = tm.Update(keyMsg(r))
	}
	tm, _ = tm.Update(tea.KeyMsg{Type: tea.KeyEnter})

	if len(actions.relayCalls) != 1 {
		t.Fatalf("expected one relay call, got %#v", actions.relayCalls)
	}
	if actions.relayCalls[0] != (relayCall{workerID: "party-other-worker", message: "ping"}) {
		t.Fatalf("unexpected relay call: %#v", actions.relayCalls[0])
	}
}

func TestTrackerUpdateRelayOnCurrentRowSetsError(t *testing.T) {
	t.Parallel()

	actions := &fakeActions{}
	tm := newTestTracker(SessionInfo{ID: "party-current"}, TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "party-current", Title: "current", Status: "active", SessionType: "standalone", IsCurrent: true},
			{ID: "party-other", Title: "other", Status: "active", SessionType: "standalone"},
		},
	}, actions)
	tm.cursor = 0

	tm, _ = tm.Update(keyMsg('r'))
	if tm.mode != trackerModeNormal {
		t.Fatalf("expected normal mode, got %v", tm.mode)
	}
	if tm.lastErr == nil {
		t.Fatalf("expected lastErr to be set when relaying to current row")
	}
	if len(actions.relayCalls) != 0 {
		t.Fatalf("expected no relay calls, got %#v", actions.relayCalls)
	}
}

func TestTrackerUpdateRelayOnStoppedRowSetsError(t *testing.T) {
	t.Parallel()

	actions := &fakeActions{}
	tm := newTestTracker(SessionInfo{ID: "party-current"}, TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "party-current", Title: "current", Status: "active", SessionType: "standalone", IsCurrent: true},
			{ID: "party-dead", Title: "dead", Status: "stopped", SessionType: "standalone"},
		},
	}, actions)
	tm.cursor = 1

	tm, _ = tm.Update(keyMsg('r'))
	if tm.mode != trackerModeNormal {
		t.Fatalf("expected normal mode, got %v", tm.mode)
	}
	if tm.lastErr == nil {
		t.Fatalf("expected lastErr to be set when relaying to stopped row")
	}
}

func TestTrackerUpdateDeleteSelectedSessionOutsideMaster(t *testing.T) {
	t.Parallel()

	actions := &fakeActions{}
	tm := newTestTracker(SessionInfo{ID: "party-worker", SessionType: "worker"}, TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "party-master", Title: "master", Status: "active", SessionType: "master"},
			{ID: "party-worker", Title: "current", Status: "active", SessionType: "worker", ParentID: "party-master", IsCurrent: true},
		},
	}, actions)
	tm.cursor = 1

	tm, _ = tm.Update(keyMsg('d'))

	if len(actions.deleteCalls) != 1 {
		t.Fatalf("expected one delete call, got %#v", actions.deleteCalls)
	}
	if actions.deleteCalls[0] != (deleteCall{ownerID: "party-master", targetID: "party-worker"}) {
		t.Fatalf("unexpected delete call: %#v", actions.deleteCalls[0])
	}
}

func TestTrackerUpdateDeleteCurrentSessionAttachesNextActive(t *testing.T) {
	t.Parallel()

	actions := &fakeActions{}
	tm := newTestTracker(SessionInfo{ID: "party-current", SessionType: "standalone"}, TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "party-current", Title: "current", Status: "active", SessionType: "standalone", IsCurrent: true},
			{ID: "party-stopped", Title: "stopped", Status: "stopped", SessionType: "standalone"},
			{ID: "party-target", Title: "target", Status: "active", SessionType: "standalone"},
		},
	}, actions)

	tm, _ = tm.Update(keyMsg('d'))

	if len(actions.deleteCalls) != 1 {
		t.Fatalf("expected one delete call, got %#v", actions.deleteCalls)
	}
	if len(actions.attachCalls) != 1 || actions.attachCalls[0] != "party-target" {
		t.Fatalf("expected attach to party-target, got %#v", actions.attachCalls)
	}
}

func TestTrackerUpdateDeleteCurrentSessionFallsBackToPreviousActive(t *testing.T) {
	t.Parallel()

	actions := &fakeActions{}
	tm := newTestTracker(SessionInfo{ID: "party-current", SessionType: "standalone"}, TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "party-previous", Title: "previous", Status: "active", SessionType: "standalone"},
			{ID: "party-current", Title: "current", Status: "active", SessionType: "standalone", IsCurrent: true},
			{ID: "party-stopped", Title: "stopped", Status: "stopped", SessionType: "standalone"},
		},
	}, actions)

	tm, _ = tm.Update(keyMsg('d'))

	if len(actions.attachCalls) != 1 || actions.attachCalls[0] != "party-previous" {
		t.Fatalf("expected attach to party-previous, got %#v", actions.attachCalls)
	}
}

func TestTrackerUpdateDeleteCurrentMasterSkipsDeletedWorkers(t *testing.T) {
	t.Parallel()

	actions := &fakeActions{}
	tm := newTestTracker(SessionInfo{ID: "party-master", SessionType: "master"}, TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "party-master", Title: "master", Status: "active", SessionType: "master", IsCurrent: true},
			{ID: "party-worker", Title: "worker", Status: "active", SessionType: "worker", ParentID: "party-master"},
			{ID: "party-target", Title: "target", Status: "active", SessionType: "standalone"},
		},
	}, actions)

	tm, _ = tm.Update(keyMsg('d'))

	if len(actions.attachCalls) != 1 || actions.attachCalls[0] != "party-target" {
		t.Fatalf("expected attach to party-target, got %#v", actions.attachCalls)
	}
}

func TestTrackerUpdateDeleteNonCurrentSessionDoesNotAttach(t *testing.T) {
	t.Parallel()

	actions := &fakeActions{}
	tm := newTestTracker(SessionInfo{ID: "party-current", SessionType: "standalone"}, TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "party-current", Title: "current", Status: "active", SessionType: "standalone", IsCurrent: true},
			{ID: "party-other", Title: "other", Status: "active", SessionType: "standalone"},
		},
	}, actions)
	tm.cursor = 1

	tm, _ = tm.Update(keyMsg('d'))

	if len(actions.deleteCalls) != 1 {
		t.Fatalf("expected one delete call, got %#v", actions.deleteCalls)
	}
	if len(actions.attachCalls) != 0 {
		t.Fatalf("expected no attach for non-current delete, got %#v", actions.attachCalls)
	}
}

func renderTrackerANSI(style lipgloss.Style, text string) string {
	r := lipgloss.NewRenderer(io.Discard)
	r.SetColorProfile(termenv.TrueColor)
	return r.NewStyle().Inherit(style).Render(text)
}

func TestTrackerRefreshSessionsFallsBackToCurrentWhenSelectionDisappears(t *testing.T) {
	t.Parallel()

	tm := newTestTracker(SessionInfo{ID: "party-current"}, TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "party-current", Title: "current", Status: "active", SessionType: "standalone", IsCurrent: true},
			{ID: "party-target", Title: "target", Status: "active", SessionType: "standalone"},
		},
	}, &fakeActions{})
	tm.cursor = 1
	tm.applySnapshot(TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "party-current", Title: "current", Status: "active", SessionType: "standalone", IsCurrent: true},
			{ID: "party-other", Title: "other", Status: "active", SessionType: "standalone"},
		},
	})

	row, ok := tm.selectedSession()
	if !ok || row.ID != "party-current" {
		t.Fatalf("expected refresh to fall back to current session, got %#v", row)
	}
}

func TestTrackerViewShowsCurrentIndicator(t *testing.T) {
	lipgloss.SetColorProfile(termenv.TrueColor)
	t.Cleanup(func() {
		lipgloss.SetColorProfile(termenv.Ascii)
	})

	snapshot := TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "party-current", Title: "current", Status: "active", SessionType: "standalone", PrimaryAgent: "claude", IsCurrent: true},
			{ID: "party-other", Title: "other", Status: "active", SessionType: "standalone", PrimaryAgent: "claude"},
		},
	}

	tm := newTestTracker(SessionInfo{ID: "party-current"}, snapshot, &fakeActions{})
	view := tm.View()

	// Current row is also the selected row in this fixture; the title
	// renders with the selected-row background tint inherited over the
	// agent identity + Bold style.
	styledCurrent := selectedStyledText(titleStyleForRow("claude", true, true), "current")
	if !strings.Contains(view, styledCurrent) {
		t.Fatalf("expected current-session title styled with agent identity + bold + selected bg, got:\n%s", view)
	}

	// The non-current "other" row renders in steady agent color, no bold.
	styledOther := titleStyleForRow("claude", false, false).Render("other")
	if !strings.Contains(view, styledOther) {
		t.Fatalf("expected non-current row title in steady agent color, got:\n%s", view)
	}
}

func TestTrackerPreservesLastSnippetWhenRefreshIsEmpty(t *testing.T) {
	t.Parallel()

	tm := NewTrackerModel(SessionInfo{ID: "party-current"}, nil, &fakeActions{})
	observedAt := time.Date(2026, time.May, 7, 12, 0, 0, 0, time.UTC)
	tm.applySnapshot(TrackerSnapshot{
		Sessions:   []SessionRow{{ID: "party-current", Status: "active", SessionType: "standalone", Snippet: "last useful update"}},
		ObservedAt: observedAt,
	})
	tm.applySnapshot(TrackerSnapshot{
		Sessions:   []SessionRow{{ID: "party-current", Status: "active", SessionType: "standalone"}},
		ObservedAt: observedAt.Add(time.Minute),
	})

	row, ok := tm.selectedSession()
	if !ok {
		t.Fatal("expected selected session")
	}
	if row.Snippet != "last useful update" {
		t.Fatalf("snippet = %q, want previous non-empty snippet", row.Snippet)
	}
	if row.State == "working" {
		t.Fatal("preserving a snippet should not keep the activity dot active")
	}
}

func BenchmarkTrackerRelayInputKeystroke(b *testing.B) {
	tm := newTestTracker(
		SessionInfo{ID: "party-master", SessionType: "master"},
		benchmarkTrackerSnapshot(),
		&fakeActions{},
	)
	tm.cursor = 1
	tm, _ = tm.Update(keyMsg('r'))

	keys := []rune("abcdefghijklmnopqrstuvwxyz")
	b.ReportAllocs()
	b.ResetTimer()

	for i := 0; i < b.N; i++ {
		if len(tm.input.Value()) >= tm.input.CharLimit {
			tm.input.SetValue("")
		}
		tm, _ = tm.Update(keyMsg(keys[i%len(keys)]))
		_ = tm.View()
	}
}
