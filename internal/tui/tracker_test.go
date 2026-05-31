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

	"github.com/alexivison/questmaster/internal/message"
)

type fakeActions struct {
	attachCalls     []string
	continueCalls   []string
	continueErr     error
	relayCalls      []relayCall
	broadcastCalls  []broadcastCall
	broadcastResult message.BroadcastResult
	spawnCalls      []spawnCall
	deleteCalls     []deleteCall
	setColorCalls   []setColorCall
	manifestJSON    map[string]string
	err             error
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

type setColorCall struct {
	sessionID string
	color     string
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

func (f *fakeActions) Broadcast(_ context.Context, masterID, msg string) (message.BroadcastResult, error) {
	f.broadcastCalls = append(f.broadcastCalls, broadcastCall{masterID: masterID, message: msg})
	return f.broadcastResult, f.err
}

func (f *fakeActions) Spawn(_ context.Context, masterID, title string) error {
	f.spawnCalls = append(f.spawnCalls, spawnCall{masterID: masterID, title: title})
	return f.err
}

func (f *fakeActions) Delete(_ context.Context, ownerID, workerID string) error {
	f.deleteCalls = append(f.deleteCalls, deleteCall{ownerID: ownerID, targetID: workerID})
	return f.err
}

func (f *fakeActions) SetDisplayColor(sessionID, color string) error {
	f.setColorCalls = append(f.setColorCalls, setColorCall{sessionID: sessionID, color: color})
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
	return tm.syncFrameCaches()
}

func keyMsg(r rune) tea.KeyMsg {
	return tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}}
}

func benchmarkTrackerSnapshot() TrackerSnapshot {
	sessions := []SessionRow{
		{
			ID:           "qm-master",
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
			ID:           fmt.Sprintf("qm-worker-%02d", i),
			Title:        fmt.Sprintf("worker-%02d", i),
			Cwd:          fmt.Sprintf("/tmp/worker-%02d", i),
			Status:       "active",
			SessionType:  "worker",
			ParentID:     "qm-master",
			PrimaryAgent: "codex",
			State:        map[bool]string{true: "working", false: "idle"}[i%2 == 0],
			Snippet:      fmt.Sprintf("• worker %02d status update", i),
		})
	}
	for i := range 10 {
		sessions = append(sessions, SessionRow{
			ID:           fmt.Sprintf("qm-standalone-%02d", i),
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

func idleBenchmarkTrackerSnapshot() TrackerSnapshot {
	snapshot := benchmarkTrackerSnapshot()
	for i := range snapshot.Sessions {
		snapshot.Sessions[i].State = "idle"
		snapshot.Sessions[i].WorkingSince = time.Time{}
	}
	return snapshot
}

func TestTrackerViewNoSessions(t *testing.T) {
	t.Parallel()

	tm := newTestTracker(SessionInfo{ID: "qm-solo"}, TrackerSnapshot{}, &fakeActions{})
	view := tm.View()

	if !strings.Contains(view, "No sessions") {
		t.Fatalf("expected empty-state message, got:\n%s", view)
	}
}

func TestTrackerViewShowsHierarchy(t *testing.T) {
	t.Parallel()

	snapshot := TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "qm-1230", Title: "Project Alpha", Cwd: "/tmp/project-alpha", Status: "active", SessionType: "master", WorkerCount: 2, PrimaryAgent: "claude", IsCurrent: true, State: "idle"},
			{ID: "qm-1231", Title: "fix-auth", Cwd: "/tmp/fix-auth", Status: "active", SessionType: "worker", ParentID: "qm-1230", PrimaryAgent: "claude", Snippet: "❯ make test\n⏺ running tests", State: "idle"},
			{ID: "qm-1232", Title: "dark-mode", Cwd: "/tmp/dark-mode", Status: "active", SessionType: "worker", ParentID: "qm-1230", PrimaryAgent: "codex", Snippet: "• review queued", State: "idle"},
			{ID: "qm-1236", Title: "solo task", Cwd: "/tmp/solo", Status: "active", SessionType: "standalone", PrimaryAgent: "codex", Snippet: "❯ npm test\n⎿ 42 passed", State: "idle"},
			{ID: "qm-1237", Title: "no-agent", Cwd: "/tmp/no-agent", Status: "active", SessionType: "standalone", State: "idle"},
		},
		Current: CurrentSessionDetail{
			Title:       "Project Alpha",
			SessionType: "master",
		},
	}

	tm := newTestTracker(SessionInfo{ID: "qm-1230", SessionType: "master"}, snapshot, &fakeActions{})
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
	for _, needle := range []string{"qm-1231", "/tmp/fix-auth"} {
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
	if !strings.Contains(view, "⚔ qm-1230") {
		t.Fatalf("expected ⚔ icon on master metadata row, got:\n%s", view)
	}
	if !strings.Contains(view, "⚒ qm-1231") {
		t.Fatalf("expected ⚒ icon on worker metadata row, got:\n%s", view)
	}
	if !strings.Contains(view, "✠ qm-1236") {
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
			{ID: "qm-2001", Title: "bugfix", Status: "active", SessionType: "worker", ParentID: "qm-master", PrimaryAgent: "codex", Snippet: "❯ fix lint", IsCurrent: true},
		},
		Current: CurrentSessionDetail{
			Title:       "bugfix",
			SessionType: "worker",
		},
	}

	tm := newTestTracker(SessionInfo{ID: "qm-2001", SessionType: "worker"}, snapshot, &fakeActions{})
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
			{ID: "qm-master", Title: "Project Alpha", Status: "active", SessionType: "master", PrimaryAgent: "claude", IsCurrent: true},
		},
		Current: CurrentSessionDetail{
			Title:       "Project Alpha",
			SessionType: "master",
		},
	}

	tm := newTestTracker(SessionInfo{ID: "qm-master", SessionType: "master"}, snapshot, &fakeActions{})
	view := tm.View()

	expectedTitle := renderTrackerANSI(paneTitleStyle, "⚔ Project Alpha (qm-master)")
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
			{ID: "qm-master", Title: "Project Alpha", Status: "active", SessionType: "master", PrimaryAgent: "claude"},
			{ID: "qm-worker", Title: "Investigate", Status: "active", SessionType: "worker", ParentID: "qm-master", PrimaryAgent: "codex", IsCurrent: true},
		},
		Current: CurrentSessionDetail{
			Title:       "Investigate",
			SessionType: "worker",
		},
	}

	tm := newTestTracker(SessionInfo{ID: "qm-worker", SessionType: "worker"}, snapshot, &fakeActions{})
	view := tm.View()

	expectedTitle := renderTrackerANSI(paneTitleStyle, "⚒ Investigate (qm-worker)")
	if !strings.Contains(view, expectedTitle) {
		t.Fatalf("expected worker tracker header with worker role glyph, got:\n%s", view)
	}

	// Pane title must no longer carry any agent-color foreground.
	codexTinted := renderTrackerANSI(paneTitleStyle.Foreground(agentIdentityStyle("codex").GetForeground()), "⚒ Investigate (qm-worker)")
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
			{ID: "qm-current", Status: "active", SessionType: "standalone", PrimaryAgent: "pi", IsCurrent: true},
		},
		Current: CurrentSessionDetail{
			SessionType: "standalone",
		},
	}

	tm := newTestTracker(SessionInfo{ID: "qm-current", SessionType: "standalone"}, snapshot, &fakeActions{})
	view := tm.View()

	expectedTitle := renderTrackerANSI(paneTitleStyle, "✠ qm-current")
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
					{ID: "qm-x", Title: "Demo", Status: "active", SessionType: tc.sessionType, PrimaryAgent: "claude", IsCurrent: true},
				},
				Current: CurrentSessionDetail{Title: "Demo", SessionType: tc.sessionType},
			}
			tm := newTestTracker(SessionInfo{ID: "qm-x", SessionType: tc.sessionType}, snapshot, &fakeActions{})
			view := tm.View()

			expectedTitle := renderTrackerANSI(paneTitleStyle, tc.wantGlyph+" Demo (qm-x)")
			if !strings.Contains(view, expectedTitle) {
				t.Fatalf("session type %q: expected pane title with glyph %q, got:\n%s", tc.sessionType, tc.wantGlyph, view)
			}

			tinted := renderTrackerANSI(paneTitleStyle.Foreground(agentIdentityStyle("claude").GetForeground()), tc.wantGlyph+" Demo (qm-x)")
			if strings.Contains(view, tinted) {
				t.Fatalf("session type %q: pane title must not be tinted with the agent color, got:\n%s", tc.sessionType, view)
			}
		})
	}
}

func TestTrackerViewShowsErrorInStatusBarWithoutFooter(t *testing.T) {
	t.Parallel()

	tm := newTestTracker(SessionInfo{ID: "qm-master", SessionType: "master"}, TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "qm-master", Title: "orchestrator", Status: "active", SessionType: "master", PrimaryAgent: "claude", IsCurrent: true},
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

	tm := newTestTracker(SessionInfo{ID: "qm-current"}, TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "qm-current", Title: "current", Status: "active", SessionType: "standalone", IsCurrent: true},
			{ID: "qm-other", Title: "other", Status: "active", SessionType: "standalone"},
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
		ID:           "qm-worker",
		Title:        "investigate",
		Cwd:          "/tmp/project",
		Status:       "active",
		SessionType:  "worker",
		ParentID:     "qm-master",
		PrimaryAgent: "claude",
		State:        "working",
		Snippet:      "⏺ running tests",
	}
	tm := TrackerModel{
		cursor:   0,
		sessions: []SessionRow{row, {ID: "qm-sibling", SessionType: "worker", ParentID: "qm-master"}},
	}

	const innerW = 48
	got := tm.renderSessionRow(row, 0, innerW)
	lines := strings.Split(got, "\n")
	if len(lines) != 3 {
		t.Fatalf("selected row line count = %d, want 3\n%s", len(lines), got)
	}

	selectedTree := renderTrackerANSI(selectedRowStyle.Inherit(treeGutterStyleFor()), "┣━ ")
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
		t.Fatalf("selected title line missing selected tree gutter\n%q", lines[0])
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
		ID:           "qm-worker",
		Title:        "investigate",
		Cwd:          "/tmp/project",
		Status:       "active",
		SessionType:  "worker",
		ParentID:     "qm-master",
		PrimaryAgent: "claude",
		State:        "working",
		Snippet:      "⏺ running tests with a long snippet",
	}
	tm := TrackerModel{
		cursor:   0,
		sessions: []SessionRow{row, {ID: "qm-sibling", SessionType: "worker", ParentID: "qm-master"}},
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
	tm := newTestTracker(SessionInfo{ID: "qm-current"}, TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "qm-current", Title: "current", Status: "active", SessionType: "standalone", IsCurrent: true},
			{ID: "qm-target", Title: "target", Status: "active", SessionType: "standalone"},
		},
	}, actions)
	tm.cursor = 1

	tm, _ = tm.Update(tea.KeyMsg{Type: tea.KeyEnter})

	if len(actions.attachCalls) != 1 || actions.attachCalls[0] != "qm-target" {
		t.Fatalf("expected attach to selected active session, got %#v", actions.attachCalls)
	}
	if len(actions.continueCalls) != 0 {
		t.Fatalf("expected no continue calls for active row, got %#v", actions.continueCalls)
	}
}

func TestTrackerUpdateEnterResumesStoppedSession(t *testing.T) {
	t.Parallel()

	actions := &fakeActions{}
	tm := newTestTracker(SessionInfo{ID: "qm-current"}, TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "qm-current", Title: "current", Status: "active", SessionType: "standalone", IsCurrent: true},
			{ID: "qm-stopped", Title: "stopped", Status: "stopped", SessionType: "standalone"},
		},
	}, actions)
	tm.cursor = 1

	tm, _ = tm.Update(tea.KeyMsg{Type: tea.KeyEnter})

	if len(actions.continueCalls) != 1 || actions.continueCalls[0] != "qm-stopped" {
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
	tm := newTestTracker(SessionInfo{ID: "qm-current"}, TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "qm-current", Title: "current", Status: "active", SessionType: "standalone", IsCurrent: true},
			{ID: "qm-stopped", Title: "stopped", Status: "stopped", SessionType: "standalone"},
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
	tm := newTestTracker(SessionInfo{ID: "qm-master"}, TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "qm-master", Title: "master", Status: "active", SessionType: "master", IsCurrent: true},
			{ID: "qm-worker", Title: "worker", Status: "active", SessionType: "worker", ParentID: "qm-master"},
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
	if actions.relayCalls[0].workerID != "qm-worker" || actions.relayCalls[0].message != "investigate" {
		t.Fatalf("unexpected relay call: %#v", actions.relayCalls[0])
	}
}

func TestTrackerRelayTypingReusesCachedSessionPane(t *testing.T) {
	t.Parallel()

	tm := newTestTracker(
		SessionInfo{ID: "qm-master", SessionType: "master"},
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

func TestTrackerNormalViewCacheHitMatchesUncachedRender(t *testing.T) {
	t.Parallel()

	tm := newTestTracker(
		SessionInfo{ID: "qm-master", SessionType: "master"},
		idleBenchmarkTrackerSnapshot(),
		&fakeActions{},
	)
	outerW, outerH := clampDimensions(tm.width, tm.height)
	uncached := tm.renderNormalFrame(outerW, outerH)
	cached := tm.View()
	if cached != uncached {
		t.Fatal("cached normal view must be byte-identical to uncached render")
	}

	rowRenders := 0
	tm.testHooks.renderSessionRow = func() { rowRenders++ }
	if got := tm.View(); got != cached {
		t.Fatal("normal view cache hit changed output bytes")
	}
	if rowRenders != 0 {
		t.Fatalf("expected normal view cache hit, got %d row renders", rowRenders)
	}
}

func TestTrackerNormalViewCacheInvalidatesOnMutations(t *testing.T) {
	current := SessionInfo{ID: "qm-master", SessionType: "master"}

	t.Run("snapshot", func(t *testing.T) {
		tm := newTestTracker(current, idleBenchmarkTrackerSnapshot(), &fakeActions{})
		if !tm.normalFrameCache.valid {
			t.Fatal("expected primed normal cache")
		}
		snapshot := idleBenchmarkTrackerSnapshot()
		snapshot.Sessions[0].Title = "renamed orchestrator"
		tm.applySnapshot(snapshot)
		if tm.normalFrameCache.valid {
			t.Fatal("snapshot should invalidate normal cache")
		}
	})

	t.Run("cursor", func(t *testing.T) {
		tm := newTestTracker(current, idleBenchmarkTrackerSnapshot(), &fakeActions{})
		tm, _ = tm.updateNormal(keyMsg('j'))
		if tm.normalFrameCache.valid {
			t.Fatal("cursor move should invalidate normal cache")
		}
	})

	t.Run("last error", func(t *testing.T) {
		tm := newTestTracker(current, idleBenchmarkTrackerSnapshot(), &fakeActions{})
		tm, _ = tm.updateNormal(keyMsg('r'))
		if tm.lastErr == nil {
			t.Fatal("expected relay error")
		}
		if tm.normalFrameCache.valid {
			t.Fatal("lastErr change should invalidate normal cache")
		}
	})

	t.Run("working spinner", func(t *testing.T) {
		tm := newTestTracker(current, benchmarkTrackerSnapshot(), &fakeActions{})
		rowRenders := 0
		tm.testHooks.renderSessionRow = func() { rowRenders++ }
		m := Model{tracker: tm}
		updated, _ := m.Update(spinnerTickMsg{})
		model := updated.(Model)
		if rowRenders == 0 {
			t.Fatal("working spinner tick should rebuild normal cache")
		}
		if !model.tracker.normalFrameCache.valid {
			t.Fatal("expected normal cache rebuilt after working spinner tick")
		}
		if got, want := model.tracker.normalFrameCache.key.spinnerFrame, tm.spinnerFrame+1; got != want {
			t.Fatalf("spinner cache key = %d, want %d", got, want)
		}
	})

	t.Run("idle spinner", func(t *testing.T) {
		tm := newTestTracker(current, idleBenchmarkTrackerSnapshot(), &fakeActions{})
		rowRenders := 0
		tm.testHooks.renderSessionRow = func() { rowRenders++ }
		m := Model{tracker: tm}
		updated, _ := m.Update(spinnerTickMsg{})
		model := updated.(Model)
		if rowRenders != 0 {
			t.Fatalf("idle spinner tick should not rebuild normal cache, got %d row renders", rowRenders)
		}
		if !model.tracker.normalFrameCache.valid {
			t.Fatal("idle spinner tick should leave normal cache valid")
		}
	})

	t.Run("window size", func(t *testing.T) {
		tm := newTestTracker(current, idleBenchmarkTrackerSnapshot(), &fakeActions{})
		rowRenders := 0
		tm.testHooks.renderSessionRow = func() { rowRenders++ }
		m := Model{Width: tm.width, Height: tm.height, tracker: tm}
		updated, _ := m.Update(tea.WindowSizeMsg{Width: 100, Height: 90})
		model := updated.(Model)
		if rowRenders == 0 {
			t.Fatal("window resize should rebuild normal cache")
		}
		if got := model.tracker.normalFrameCache.key.width; got != 100 {
			t.Fatalf("cache width = %d, want 100", got)
		}
		if got := model.tracker.normalFrameCache.key.height; got != 90 {
			t.Fatalf("cache height = %d, want 90", got)
		}
	})
}

func TestTrackerUpdateBroadcastOnCurrentMaster(t *testing.T) {
	t.Parallel()

	actions := &fakeActions{}
	tm := newTestTracker(SessionInfo{ID: "qm-master"}, TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "qm-master", Title: "master", Status: "active", SessionType: "master", IsCurrent: true},
			{ID: "qm-worker", Title: "worker", Status: "active", SessionType: "worker", ParentID: "qm-master"},
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
	if actions.broadcastCalls[0] != (broadcastCall{masterID: "qm-master", message: "take stock"}) {
		t.Fatalf("unexpected broadcast call: %#v", actions.broadcastCalls[0])
	}
}

func TestTrackerBroadcastZeroDeliverySetsError(t *testing.T) {
	t.Parallel()

	actions := &fakeActions{broadcastResult: message.BroadcastResult{Registered: 2, Delivered: 0}}
	tm := newTestTracker(SessionInfo{ID: "qm-master"}, TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "qm-master", Title: "master", Status: "active", SessionType: "master", IsCurrent: true},
			{ID: "qm-worker", Title: "worker", Status: "active", SessionType: "worker", ParentID: "qm-master"},
		},
		Current: CurrentSessionDetail{SessionType: "master"},
	}, actions)

	tm, _ = tm.Update(keyMsg('b'))
	for _, r := range "ping" {
		tm, _ = tm.Update(keyMsg(r))
	}
	tm, _ = tm.Update(tea.KeyMsg{Type: tea.KeyEnter})

	if tm.lastErr == nil {
		t.Fatal("broadcast reaching 0 of 2 registered workers must surface a status, not be silent")
	}
	if !strings.Contains(tm.lastErr.Error(), "0 of 2") {
		t.Fatalf("expected delivered/registered counts in status, got %q", tm.lastErr.Error())
	}
}

func TestTrackerBroadcastFullDeliveryIsSilent(t *testing.T) {
	t.Parallel()

	actions := &fakeActions{broadcastResult: message.BroadcastResult{Registered: 2, Delivered: 2}}
	tm := newTestTracker(SessionInfo{ID: "qm-master"}, TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "qm-master", Title: "master", Status: "active", SessionType: "master", IsCurrent: true},
			{ID: "qm-worker", Title: "worker", Status: "active", SessionType: "worker", ParentID: "qm-master"},
		},
		Current: CurrentSessionDetail{SessionType: "master"},
	}, actions)

	tm, _ = tm.Update(keyMsg('b'))
	for _, r := range "ping" {
		tm, _ = tm.Update(keyMsg(r))
	}
	tm, _ = tm.Update(tea.KeyMsg{Type: tea.KeyEnter})

	if tm.lastErr != nil {
		t.Fatalf("full delivery should be silent, got status %q", tm.lastErr.Error())
	}
}

func TestTrackerUpdateRelayToActiveNonCurrentSessionFromNonMaster(t *testing.T) {
	t.Parallel()

	actions := &fakeActions{}
	tm := newTestTracker(SessionInfo{ID: "qm-worker", SessionType: "worker"}, TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "qm-master", Title: "master", Status: "active", SessionType: "master"},
			{ID: "qm-other-worker", Title: "sibling", Status: "active", SessionType: "worker", ParentID: "qm-master"},
			{ID: "qm-worker", Title: "current", Status: "active", SessionType: "worker", ParentID: "qm-master", IsCurrent: true},
		},
	}, actions)
	tm.cursor = 1

	tm, _ = tm.Update(keyMsg('r'))
	if tm.mode != trackerModeRelay {
		t.Fatalf("expected relay mode, got %v", tm.mode)
	}
	if tm.relayTargetID != "qm-other-worker" {
		t.Fatalf("expected relay target qm-other-worker, got %q", tm.relayTargetID)
	}

	for _, r := range "ping" {
		tm, _ = tm.Update(keyMsg(r))
	}
	tm, _ = tm.Update(tea.KeyMsg{Type: tea.KeyEnter})

	if len(actions.relayCalls) != 1 {
		t.Fatalf("expected one relay call, got %#v", actions.relayCalls)
	}
	if actions.relayCalls[0] != (relayCall{workerID: "qm-other-worker", message: "ping"}) {
		t.Fatalf("unexpected relay call: %#v", actions.relayCalls[0])
	}
}

func TestTrackerUpdateRelayOnCurrentRowSetsError(t *testing.T) {
	t.Parallel()

	actions := &fakeActions{}
	tm := newTestTracker(SessionInfo{ID: "qm-current"}, TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "qm-current", Title: "current", Status: "active", SessionType: "standalone", IsCurrent: true},
			{ID: "qm-other", Title: "other", Status: "active", SessionType: "standalone"},
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
	tm := newTestTracker(SessionInfo{ID: "qm-current"}, TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "qm-current", Title: "current", Status: "active", SessionType: "standalone", IsCurrent: true},
			{ID: "qm-dead", Title: "dead", Status: "stopped", SessionType: "standalone"},
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
	tm := newTestTracker(SessionInfo{ID: "qm-worker", SessionType: "worker"}, TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "qm-master", Title: "master", Status: "active", SessionType: "master"},
			{ID: "qm-worker", Title: "current", Status: "active", SessionType: "worker", ParentID: "qm-master", IsCurrent: true},
		},
	}, actions)
	tm.cursor = 1

	tm, _ = tm.Update(keyMsg('d'))

	if len(actions.deleteCalls) != 1 {
		t.Fatalf("expected one delete call, got %#v", actions.deleteCalls)
	}
	if actions.deleteCalls[0] != (deleteCall{ownerID: "qm-master", targetID: "qm-worker"}) {
		t.Fatalf("unexpected delete call: %#v", actions.deleteCalls[0])
	}
}

func TestTrackerUpdateDeleteCurrentSessionAttachesNextActive(t *testing.T) {
	t.Parallel()

	actions := &fakeActions{}
	tm := newTestTracker(SessionInfo{ID: "qm-current", SessionType: "standalone"}, TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "qm-current", Title: "current", Status: "active", SessionType: "standalone", IsCurrent: true},
			{ID: "qm-stopped", Title: "stopped", Status: "stopped", SessionType: "standalone"},
			{ID: "qm-target", Title: "target", Status: "active", SessionType: "standalone"},
		},
	}, actions)

	tm, _ = tm.Update(keyMsg('d'))

	if len(actions.deleteCalls) != 1 {
		t.Fatalf("expected one delete call, got %#v", actions.deleteCalls)
	}
	if len(actions.attachCalls) != 1 || actions.attachCalls[0] != "qm-target" {
		t.Fatalf("expected attach to qm-target, got %#v", actions.attachCalls)
	}
}

func TestTrackerUpdateDeleteCurrentSessionFallsBackToPreviousActive(t *testing.T) {
	t.Parallel()

	actions := &fakeActions{}
	tm := newTestTracker(SessionInfo{ID: "qm-current", SessionType: "standalone"}, TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "qm-previous", Title: "previous", Status: "active", SessionType: "standalone"},
			{ID: "qm-current", Title: "current", Status: "active", SessionType: "standalone", IsCurrent: true},
			{ID: "qm-stopped", Title: "stopped", Status: "stopped", SessionType: "standalone"},
		},
	}, actions)

	tm, _ = tm.Update(keyMsg('d'))

	if len(actions.attachCalls) != 1 || actions.attachCalls[0] != "qm-previous" {
		t.Fatalf("expected attach to qm-previous, got %#v", actions.attachCalls)
	}
}

func TestTrackerUpdateDeleteCurrentMasterSkipsDeletedWorkers(t *testing.T) {
	t.Parallel()

	actions := &fakeActions{}
	tm := newTestTracker(SessionInfo{ID: "qm-master", SessionType: "master"}, TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "qm-master", Title: "master", Status: "active", SessionType: "master", IsCurrent: true},
			{ID: "qm-worker", Title: "worker", Status: "active", SessionType: "worker", ParentID: "qm-master"},
			{ID: "qm-target", Title: "target", Status: "active", SessionType: "standalone"},
		},
	}, actions)

	tm, _ = tm.Update(keyMsg('d'))

	if len(actions.attachCalls) != 1 || actions.attachCalls[0] != "qm-target" {
		t.Fatalf("expected attach to qm-target, got %#v", actions.attachCalls)
	}
}

func TestTrackerUpdateDeleteNonCurrentSessionDoesNotAttach(t *testing.T) {
	t.Parallel()

	actions := &fakeActions{}
	tm := newTestTracker(SessionInfo{ID: "qm-current", SessionType: "standalone"}, TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "qm-current", Title: "current", Status: "active", SessionType: "standalone", IsCurrent: true},
			{ID: "qm-other", Title: "other", Status: "active", SessionType: "standalone"},
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

	tm := newTestTracker(SessionInfo{ID: "qm-current"}, TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "qm-current", Title: "current", Status: "active", SessionType: "standalone", IsCurrent: true},
			{ID: "qm-target", Title: "target", Status: "active", SessionType: "standalone"},
		},
	}, &fakeActions{})
	tm.cursor = 1
	tm.applySnapshot(TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "qm-current", Title: "current", Status: "active", SessionType: "standalone", IsCurrent: true},
			{ID: "qm-other", Title: "other", Status: "active", SessionType: "standalone"},
		},
	})

	row, ok := tm.selectedSession()
	if !ok || row.ID != "qm-current" {
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
			{ID: "qm-current", Title: "current", Status: "active", SessionType: "standalone", PrimaryAgent: "claude", IsCurrent: true},
			{ID: "qm-other", Title: "other", Status: "active", SessionType: "standalone", PrimaryAgent: "claude"},
		},
	}

	tm := newTestTracker(SessionInfo{ID: "qm-current"}, snapshot, &fakeActions{})
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

	tm := NewTrackerModel(SessionInfo{ID: "qm-current"}, nil, &fakeActions{})
	observedAt := time.Date(2026, time.May, 7, 12, 0, 0, 0, time.UTC)
	tm.applySnapshot(TrackerSnapshot{
		Sessions:   []SessionRow{{ID: "qm-current", Status: "active", SessionType: "standalone", Snippet: "last useful update"}},
		ObservedAt: observedAt,
	})
	tm.applySnapshot(TrackerSnapshot{
		Sessions:   []SessionRow{{ID: "qm-current", Status: "active", SessionType: "standalone"}},
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
		SessionInfo{ID: "qm-master", SessionType: "master"},
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

func BenchmarkTrackerNormalViewFrame(b *testing.B) {
	tm := newTestTracker(
		SessionInfo{ID: "qm-master", SessionType: "master"},
		benchmarkTrackerSnapshot(),
		&fakeActions{},
	)

	b.ReportAllocs()
	b.ResetTimer()

	for i := 0; i < b.N; i++ {
		_ = tm.View()
	}
}

func BenchmarkTrackerIdleSpinnerTickFrame(b *testing.B) {
	m := Model{tracker: newTestTracker(
		SessionInfo{ID: "qm-master", SessionType: "master"},
		idleBenchmarkTrackerSnapshot(),
		&fakeActions{},
	)}

	b.ReportAllocs()
	b.ResetTimer()

	for i := 0; i < b.N; i++ {
		updated, _ := m.Update(spinnerTickMsg{})
		m = updated.(Model)
		_ = m.View()
	}
}

func TestFormatWorkingDuration(t *testing.T) {
	t.Parallel()

	cases := map[string]struct {
		in   time.Duration
		want string
	}{
		"zero":               {0, "0s"},
		"negative":           {-5 * time.Second, "0s"},
		"sub-second":         {500 * time.Millisecond, "0s"},
		"1s":                 {time.Second, "1s"},
		"59s":                {59 * time.Second, "59s"},
		"60s rounds to 1m":   {60 * time.Second, "1m"},
		"61s":                {61 * time.Second, "1m1s"},
		"2m14s":              {2*time.Minute + 14*time.Second, "2m14s"},
		"59m59s":             {59*time.Minute + 59*time.Second, "59m59s"},
		"1h0m":               {time.Hour, "1h0m"},
		"1h59m (drops secs)": {time.Hour + 59*time.Minute + 59*time.Second, "1h59m"},
		"25h13m":             {25*time.Hour + 13*time.Minute + 7*time.Second, "25h13m"},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			if got := formatWorkingDuration(tc.in); got != tc.want {
				t.Fatalf("formatWorkingDuration(%v) = %q, want %q", tc.in, got, tc.want)
			}
		})
	}
}

func TestRenderSessionRowWorkingDurationSuffix(t *testing.T) {
	lipgloss.SetColorProfile(termenv.Ascii)

	row := SessionRow{
		ID:           "qm-w",
		Title:        "investigate",
		Status:       "active",
		SessionType:  "standalone",
		PrimaryAgent: "claude",
		State:        "working",
		WorkingSince: time.Now().Add(-5 * time.Second),
	}
	tm := TrackerModel{sessions: []SessionRow{row}}
	got := tm.renderSessionRow(row, 0, 80)
	if !strings.Contains(got, " 5s") {
		t.Fatalf("working row should render duration suffix, got:\n%q", got)
	}
}

func TestRenderSessionRowWorkingZeroSinceOmitsSuffix(t *testing.T) {
	lipgloss.SetColorProfile(termenv.Ascii)

	row := SessionRow{
		ID:           "qm-w0",
		Title:        "investigate",
		Status:       "active",
		SessionType:  "standalone",
		PrimaryAgent: "claude",
		State:        "working",
	}
	tm := TrackerModel{sessions: []SessionRow{row}}
	got := tm.renderSessionRow(row, 0, 80)
	// Strip styled content to inspect the raw text after the status word.
	plain := ansi.Strip(got)
	idx := strings.LastIndex(plain, "working")
	if idx < 0 {
		t.Fatalf("expected status word 'working' in row, got %q", plain)
	}
	after := plain[idx+len("working"):]
	// The first line ends right after 'working'; the meta line follows on a
	// new line. There must be no duration token between them.
	firstLineTail := after
	if nl := strings.IndexByte(after, '\n'); nl >= 0 {
		firstLineTail = after[:nl]
	}
	if strings.TrimRight(firstLineTail, " ") != "" {
		t.Fatalf("zero WorkingSince should not render any suffix after 'working', got tail %q", firstLineTail)
	}
}

func TestRenderSessionRowNonWorkingNeverRendersDuration(t *testing.T) {
	lipgloss.SetColorProfile(termenv.Ascii)

	row := SessionRow{
		ID:           "qm-idle",
		Title:        "done thinking",
		Status:       "active",
		SessionType:  "standalone",
		PrimaryAgent: "claude",
		State:        "idle",
		// Even if a stale WorkingSince leaks through, idle rows must not render it.
		WorkingSince: time.Now().Add(-2 * time.Minute),
	}
	tm := TrackerModel{sessions: []SessionRow{row}}
	got := tm.renderSessionRow(row, 0, 80)
	plain := ansi.Strip(got)
	for _, token := range []string{"2m", "1m", "120s"} {
		if strings.Contains(plain, token) {
			t.Fatalf("non-working row leaked duration token %q in:\n%q", token, plain)
		}
	}
}

func TestRenderSessionRowTrailingWidthAccountsForDuration(t *testing.T) {
	lipgloss.SetColorProfile(termenv.Ascii)

	longTitle := strings.Repeat("very-long-title ", 6)
	rowNoDur := SessionRow{
		ID:           "qm-1",
		Title:        longTitle,
		Status:       "active",
		SessionType:  "standalone",
		PrimaryAgent: "claude",
		State:        "working",
	}
	rowDur := rowNoDur
	rowDur.WorkingSince = time.Now().Add(-12 * time.Second) // "12s" — 3 cells + leading space

	tm := TrackerModel{}
	const innerW = 30

	tm.sessions = []SessionRow{rowNoDur}
	titleNoDur := strings.Split(tm.renderSessionRow(rowNoDur, 0, innerW), "\n")[0]
	tm.sessions = []SessionRow{rowDur}
	titleDur := strings.Split(tm.renderSessionRow(rowDur, 0, innerW), "\n")[0]

	if w := ansi.StringWidth(titleNoDur); w != innerW {
		t.Fatalf("no-duration title width = %d, want %d", w, innerW)
	}
	if w := ansi.StringWidth(titleDur); w != innerW {
		t.Fatalf("with-duration title width = %d, want %d (truncation budget must include suffix)", w, innerW)
	}
	if !strings.Contains(ansi.Strip(titleDur), "…") {
		t.Fatalf("expected the long title to be truncated with '…' when duration suffix consumes trailing budget, got:\n%q", titleDur)
	}
	if !strings.Contains(ansi.Strip(titleDur), "12s") {
		t.Fatalf("duration suffix should still be visible at narrow innerW, got:\n%q", titleDur)
	}
}

func colorTracker(t *testing.T, row SessionRow, actions TrackerActions) TrackerModel {
	t.Helper()
	tm := newTestTracker(SessionInfo{ID: "qm-current"}, TrackerSnapshot{
		Sessions: []SessionRow{row},
	}, actions)
	tm.cursor = 0
	return tm
}

func TestTrackerUpdateColorEntersAndSeedsFromCurrentColor(t *testing.T) {
	t.Parallel()

	tm := colorTracker(t, SessionRow{ID: "qm-a", Title: "a", Status: "active", SessionType: "standalone", DisplayColor: "magenta"}, &fakeActions{})

	tm, _ = tm.Update(keyMsg('c'))
	if tm.mode != trackerModeColor {
		t.Fatalf("expected color mode, got %v", tm.mode)
	}
	if tm.colorTargetID != "qm-a" {
		t.Fatalf("color target = %q, want qm-a", tm.colorTargetID)
	}
	// Seeded on the current color so nothing changes until a key is pressed.
	if got := tm.previewColor(); got != "magenta" {
		t.Fatalf("seeded preview = %q, want magenta", got)
	}
}

func TestTrackerUpdateColorSeedsEmptyAtNone(t *testing.T) {
	t.Parallel()

	tm := colorTracker(t, SessionRow{ID: "qm-a", Title: "a", Status: "active", SessionType: "standalone"}, &fakeActions{})

	tm, _ = tm.Update(keyMsg('c'))
	if got := tm.previewColor(); got != "" {
		t.Fatalf("empty-color session should seed at none, got %q", got)
	}
}

func TestTrackerUpdateColorNoSessionsIsNoOp(t *testing.T) {
	t.Parallel()

	tm := newTestTracker(SessionInfo{ID: "qm-current"}, TrackerSnapshot{}, &fakeActions{})

	tm, _ = tm.Update(keyMsg('c'))
	if tm.mode != trackerModeNormal {
		t.Fatalf("color over empty list should stay normal, got %v", tm.mode)
	}
}

func TestTrackerUpdateColorCommitWritesSelectedSessionOnly(t *testing.T) {
	t.Parallel()

	actions := &fakeActions{}
	tm := colorTracker(t, SessionRow{ID: "qm-a", Title: "a", Status: "active", SessionType: "standalone"}, actions)

	tm, _ = tm.Update(keyMsg('c'))                    // none
	tm, _ = tm.Update(tea.KeyMsg{Type: tea.KeyRight}) // blue
	tm, _ = tm.Update(tea.KeyMsg{Type: tea.KeyEnter})

	if tm.mode != trackerModeNormal {
		t.Fatalf("commit should return to normal mode, got %v", tm.mode)
	}
	if len(actions.setColorCalls) != 1 {
		t.Fatalf("expected one set-color call, got %#v", actions.setColorCalls)
	}
	if actions.setColorCalls[0] != (setColorCall{sessionID: "qm-a", color: "blue"}) {
		t.Fatalf("unexpected set-color call: %#v", actions.setColorCalls[0])
	}
}

func TestTrackerUpdateColorCancelDoesNotWrite(t *testing.T) {
	t.Parallel()

	actions := &fakeActions{}
	tm := colorTracker(t, SessionRow{ID: "qm-a", Title: "a", Status: "active", SessionType: "standalone", DisplayColor: "blue"}, actions)

	tm, _ = tm.Update(keyMsg('c'))
	tm, _ = tm.Update(tea.KeyMsg{Type: tea.KeyRight})
	tm, _ = tm.Update(tea.KeyMsg{Type: tea.KeyEsc})

	if tm.mode != trackerModeNormal {
		t.Fatalf("esc should return to normal mode, got %v", tm.mode)
	}
	if len(actions.setColorCalls) != 0 {
		t.Fatalf("esc should not write, got %#v", actions.setColorCalls)
	}
}

func TestTrackerUpdateColorCyclesArrowsAndHL(t *testing.T) {
	t.Parallel()

	arrows := colorTracker(t, SessionRow{ID: "qm-a", SessionType: "standalone"}, &fakeActions{})
	arrows, _ = arrows.Update(keyMsg('c'))
	arrows, _ = arrows.Update(tea.KeyMsg{Type: tea.KeyRight})

	hl := colorTracker(t, SessionRow{ID: "qm-a", SessionType: "standalone"}, &fakeActions{})
	hl, _ = hl.Update(keyMsg('c'))
	hl, _ = hl.Update(keyMsg('l'))

	if arrows.previewColor() != hl.previewColor() {
		t.Fatalf("h/l and arrows diverged: %q vs %q", hl.previewColor(), arrows.previewColor())
	}
	if arrows.previewColor() != "blue" {
		t.Fatalf("one step right from none should preview blue, got %q", arrows.previewColor())
	}
}

func TestTrackerUpdateColorWrapsPastEnds(t *testing.T) {
	t.Parallel()

	tm := colorTracker(t, SessionRow{ID: "qm-a", SessionType: "standalone"}, &fakeActions{})

	tm, _ = tm.Update(keyMsg('c')) // none (index 0)
	tm, _ = tm.Update(keyMsg('h')) // wrap left to last option
	if got := tm.previewColor(); got != "red" {
		t.Fatalf("left from none should wrap to red, got %q", got)
	}
	tm, _ = tm.Update(keyMsg('l')) // wrap right back to none
	if got := tm.previewColor(); got != "" {
		t.Fatalf("right from red should wrap to none, got %q", got)
	}
}

func TestTrackerColorModePreviewsSelectedRowGutter(t *testing.T) {
	lipgloss.SetColorProfile(termenv.TrueColor)
	t.Cleanup(func() { lipgloss.SetColorProfile(termenv.Ascii) })

	row := SessionRow{ID: "qm-a", Title: "investigate", Cwd: "/tmp/p", Status: "active", SessionType: "standalone", PrimaryAgent: "claude", State: "idle", Snippet: "started"}
	tm := colorTracker(t, row, &fakeActions{})

	tm, _ = tm.Update(keyMsg('c'))
	for tm.previewColor() != "magenta" {
		tm, _ = tm.Update(tea.KeyMsg{Type: tea.KeyRight})
	}

	// The cursor row is selected, so its first line must start with the
	// selected gutter rendered in the previewed (magenta) color — proving the
	// candidate color flows through to the render before any commit.
	got := tm.renderSessionRow(tm.sessions[0], 0, 60)
	wantGutter := selectedDisplayColorGutter("magenta")
	firstLine := strings.Split(got, "\n")[0]
	if !strings.HasPrefix(firstLine, wantGutter) {
		t.Fatalf("previewed row should start with magenta gutter %q\nline %q", wantGutter, firstLine)
	}
}

func TestTrackerColorModeShowsHintFooter(t *testing.T) {
	t.Parallel()

	tm := colorTracker(t, SessionRow{ID: "qm-a", Title: "a", Status: "active", SessionType: "standalone"}, &fakeActions{})

	tm, _ = tm.Update(keyMsg('c'))
	if !strings.Contains(ansi.Strip(tm.View()), ansi.Strip(colorHint)) {
		t.Fatalf("color mode view should show the color hint footer, got:\n%q", tm.View())
	}
}
