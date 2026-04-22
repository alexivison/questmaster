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

	"github.com/anthropics/ai-party/tools/party-cli/internal/tmux"
)

type fakeActions struct {
	attachCalls    []string
	relayCalls     []relayCall
	broadcastCalls []broadcastCall
	spawnCalls     []spawnCall
	stopCalls      []stopCall
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

type stopCall struct {
	ownerID  string
	targetID string
}

type deleteCall struct {
	ownerID  string
	targetID string
}

func (f *fakeActions) Attach(_ context.Context, _, targetID string) error {
	f.attachCalls = append(f.attachCalls, targetID)
	return f.err
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

func (f *fakeActions) Stop(_ context.Context, ownerID, workerID string) error {
	f.stopCalls = append(f.stopCalls, stopCall{ownerID: ownerID, targetID: workerID})
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
			{ID: "party-1230", Title: "Project Alpha", Cwd: "/tmp/project-alpha", Status: "active", SessionType: "master", WorkerCount: 2, PrimaryAgent: "claude", IsCurrent: true},
			{ID: "party-1231", Title: "fix-auth", Cwd: "/tmp/fix-auth", Status: "active", SessionType: "worker", ParentID: "party-1230", PrimaryAgent: "claude", Snippet: "❯ make test\n⏺ running tests"},
			{ID: "party-1232", Title: "dark-mode", Cwd: "/tmp/dark-mode", Status: "active", SessionType: "worker", ParentID: "party-1230", PrimaryAgent: "codex", HasCompanion: true, Snippet: "• review queued"},
			{ID: "party-1236", Title: "solo task", Cwd: "/tmp/solo", Status: "active", SessionType: "standalone", PrimaryAgent: "codex", Snippet: "❯ npm test\n⎿ 42 passed"},
		},
		Current: CurrentSessionDetail{
			ID:           "party-1230",
			Title:        "Project Alpha",
			SessionType:  "master",
			Cwd:          "~/Code/project-b",
			WorkerCount:  2,
			PrimaryAgent: "claude",
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
	if !strings.Contains(view, "companion: none") {
		t.Fatalf("expected empty companion detail for master, got:\n%s", view)
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
	// Status dots should be present for active sessions.
	if !strings.Contains(view, "●") {
		t.Fatalf("expected status dot in view, got:\n%s", view)
	}
	if !strings.Contains(view, "⚔ party-1230") {
		t.Fatalf("expected ⚔ icon on master metadata row, got:\n%s", view)
	}
	if !strings.Contains(view, "⚔ party-1231") {
		t.Fatalf("expected ⚔ icon on worker metadata row, got:\n%s", view)
	}
	if !strings.Contains(view, "●") {
		t.Fatalf("expected status dots in view, got:\n%s", view)
	}
	if !strings.Contains(view, "┃") {
		t.Fatalf("expected worker tree connector in view, got:\n%s", view)
	}
	if !strings.Contains(view, "┃") {
		t.Fatalf("expected snippet bar in view, got:\n%s", view)
	}
}

func TestTrackerViewShowsCurrentSessionDetail(t *testing.T) {
	t.Parallel()

	snapshot := TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "party-2001", Title: "bugfix", Status: "active", SessionType: "worker", ParentID: "party-master", PrimaryAgent: "codex", Snippet: "❯ fix lint", IsCurrent: true},
		},
		Current: CurrentSessionDetail{
			ID:            "party-2001",
			Title:         "bugfix",
			SessionType:   "worker",
			Cwd:           "~/Code/project",
			PrimaryAgent:  "codex",
			CompanionName: "codex",
			Evidence: []EvidenceEntry{
				{Type: "code-critic", Result: "APPROVED"},
				{Type: "minimizer", Result: "APPROVED"},
			},
		},
	}

	tm := newTestTracker(SessionInfo{ID: "party-2001", SessionType: "worker"}, snapshot, &fakeActions{})
	view := tm.View()

	for _, needle := range []string{"companion: codex", "evidence:", "code-critic", "─"} {
		if !strings.Contains(view, needle) {
			t.Fatalf("expected %q in detail view, got:\n%s", needle, view)
		}
	}
	if strings.Contains(view, "This session") {
		t.Fatalf("did not expect 'This session' header in detail view, got:\n%s", view)
	}
	if strings.Contains(view, "workers:") {
		t.Fatalf("did not expect worker count in current-session detail, got:\n%s", view)
	}
	if strings.Index(view, "companion:") > strings.LastIndex(view, "bugfix") {
		t.Fatalf("expected current-session detail above the session list, got:\n%s", view)
	}
}

func TestTrackerViewShowsPartyTitleInHeader(t *testing.T) {
	t.Parallel()

	snapshot := TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "party-master", Title: "Project Alpha", Status: "active", SessionType: "master", IsCurrent: true},
		},
		Current: CurrentSessionDetail{
			ID:          "party-master",
			Title:       "Project Alpha",
			SessionType: "master",
		},
	}

	tm := newTestTracker(SessionInfo{ID: "party-master", SessionType: "master"}, snapshot, &fakeActions{})
	view := tm.View()

	if !strings.Contains(view, "Party Tracker — Project Alpha") {
		t.Fatalf("expected titled tracker header, got:\n%s", view)
	}
}

func TestTrackerViewFallsBackToSessionHeaderWhenTitleMissing(t *testing.T) {
	t.Parallel()

	snapshot := TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "party-current", Status: "active", SessionType: "standalone", IsCurrent: true},
		},
		Current: CurrentSessionDetail{
			ID:          "party-current",
			SessionType: "standalone",
		},
	}

	tm := newTestTracker(SessionInfo{ID: "party-current", SessionType: "standalone"}, snapshot, &fakeActions{})
	view := tm.View()

	if !strings.Contains(view, "Standalone:") || !strings.Contains(view, "party-current") {
		t.Fatalf("expected legacy session header fallback, got:\n%s", view)
	}
	if strings.Contains(view, "Party Tracker —") {
		t.Fatalf("did not expect titled tracker header without a title, got:\n%s", view)
	}
}

func TestTrackerViewShowsMasterCompanionDetailWithoutRoleLine(t *testing.T) {
	t.Parallel()

	snapshot := TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "party-master", Title: "orchestrator", Status: "active", SessionType: "master", PrimaryAgent: "claude", IsCurrent: true},
		},
		Current: CurrentSessionDetail{
			ID:           "party-master",
			Title:        "orchestrator",
			SessionType:  "master",
			PrimaryAgent: "claude",
		},
	}

	tm := newTestTracker(SessionInfo{ID: "party-master", SessionType: "master"}, snapshot, &fakeActions{})
	view := tm.View()

	if !strings.Contains(view, "companion: none") {
		t.Fatalf("expected companion detail for master, got:\n%s", view)
	}
	if strings.Contains(view, "role:") {
		t.Fatalf("did not expect legacy role line, got:\n%s", view)
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

func TestTrackerRenderSessionRowTodoOverlay(t *testing.T) {
	t.Parallel()

	cases := map[string]struct {
		row         SessionRow
		wantOverlay bool
	}{
		"claude worker with overlay": {
			row: SessionRow{
				ID: "party-w", Title: "task", Cwd: "/tmp/w", Status: "active",
				SessionType: "worker", ParentID: "party-m", PrimaryAgent: "claude",
				Snippet: "⏺ running", TodoOverlay: "1/3: write tests",
			},
			wantOverlay: true,
		},
		"claude worker without overlay": {
			row: SessionRow{
				ID: "party-w", Title: "task", Cwd: "/tmp/w", Status: "active",
				SessionType: "worker", ParentID: "party-m", PrimaryAgent: "claude",
				Snippet: "⏺ running",
			},
		},
		"codex worker receives no overlay input": {
			row: SessionRow{
				ID: "party-w", Title: "task", Cwd: "/tmp/w", Status: "active",
				SessionType: "worker", ParentID: "party-m", PrimaryAgent: "codex",
				Snippet: "• awaiting",
			},
		},
	}

	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()

			tm := TrackerModel{
				cursor:   -1, // keep row unselected so overlay line appears without bg tint
				sessions: []SessionRow{tc.row},
			}
			got := tm.renderSessionRow(tc.row, 0, false, 60)
			hasOverlay := strings.Contains(got, "▸ ")
			if hasOverlay != tc.wantOverlay {
				t.Fatalf("overlay present = %v, want %v\n%s", hasOverlay, tc.wantOverlay, got)
			}
			if tc.wantOverlay && !strings.Contains(got, tc.row.TodoOverlay) {
				t.Fatalf("expected overlay text %q in output\n%s", tc.row.TodoOverlay, got)
			}
		})
	}
}

func TestTrackerRenderSessionRowSelectedRowTintCoversStyledLines(t *testing.T) {
	lipgloss.SetColorProfile(termenv.TrueColor)
	t.Cleanup(func() {
		lipgloss.SetColorProfile(termenv.Ascii)
	})

	row := SessionRow{
		ID:            "party-worker",
		Title:         "investigate",
		Cwd:           "/tmp/project",
		Status:        "active",
		SessionType:   "worker",
		ParentID:      "party-master",
		PrimaryAgent:  "claude",
		PrimaryActive: true,
		Snippet:       "⏺ running tests",
	}
	tm := TrackerModel{
		cursor:   0,
		blinkOn:  true,
		sessions: []SessionRow{row, {ID: "party-sibling", SessionType: "worker", ParentID: "party-master"}},
	}

	const innerW = 48
	got := tm.renderSessionRow(row, 0, false, innerW)
	lines := strings.Split(got, "\n")
	if len(lines) != 3 {
		t.Fatalf("selected row line count = %d, want 3\n%s", len(lines), got)
	}

	selectedTree := renderTrackerANSI(selectedRowStyle.Inherit(treeGutterStyle), "┣━ ")
	selectedDot := renderTrackerANSI(selectedRowStyle.Inherit(workerGlyphStyle), "●")
	selectedGap := renderTrackerANSI(selectedRowStyle, " ")
	selectedSnippetBar := renderTrackerANSI(selectedRowStyle.Inherit(snippetBarStyle), "┃")
	selectedMeta := renderTrackerANSI(selectedRowStyle.Inherit(metaTextStyle), "⚔ "+row.ID)

	for i, line := range lines {
		if gotW := ansi.StringWidth(line); gotW != innerW {
			t.Fatalf("line %d width = %d, want %d\n%q", i, gotW, innerW, line)
		}
	}
	if !strings.Contains(lines[0], selectedTree) {
		t.Fatalf("selected title line missing tree gutter tint\n%q", lines[0])
	}
	if !strings.Contains(lines[0], selectedDot+selectedGap) {
		t.Fatalf("selected title line missing tinted worker dot/gap\n%q", lines[0])
	}
	if !strings.Contains(lines[1], selectedSnippetBar) {
		t.Fatalf("selected snippet line missing tinted snippet bar\n%q", lines[1])
	}
	if !strings.Contains(lines[2], selectedMeta) {
		t.Fatalf("selected meta line missing tinted metadata\n%q", lines[2])
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
}

func TestTrackerUpdateRelayOnManagedWorker(t *testing.T) {
	t.Parallel()

	actions := &fakeActions{}
	tm := newTestTracker(SessionInfo{ID: "party-master"}, TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "party-master", Title: "master", Status: "active", SessionType: "master", IsCurrent: true},
			{ID: "party-worker", Title: "worker", Status: "active", SessionType: "worker", ParentID: "party-master"},
		},
		Current: CurrentSessionDetail{ID: "party-master", SessionType: "master"},
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

func TestTrackerUpdateBroadcastOnCurrentMaster(t *testing.T) {
	t.Parallel()

	actions := &fakeActions{}
	tm := newTestTracker(SessionInfo{ID: "party-master"}, TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "party-master", Title: "master", Status: "active", SessionType: "master", IsCurrent: true},
			{ID: "party-worker", Title: "worker", Status: "active", SessionType: "worker", ParentID: "party-master"},
		},
		Current: CurrentSessionDetail{ID: "party-master", SessionType: "master"},
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

func TestTrackerUpdateStopSelectedSessionOutsideMaster(t *testing.T) {
	t.Parallel()

	actions := &fakeActions{}
	tm := newTestTracker(SessionInfo{ID: "party-worker", SessionType: "worker"}, TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "party-master", Title: "master", Status: "active", SessionType: "master"},
			{ID: "party-worker", Title: "current", Status: "active", SessionType: "worker", ParentID: "party-master", IsCurrent: true},
		},
	}, actions)
	tm.cursor = 1

	tm, _ = tm.Update(keyMsg('x'))

	if len(actions.stopCalls) != 1 {
		t.Fatalf("expected one stop call, got %#v", actions.stopCalls)
	}
	if actions.stopCalls[0] != (stopCall{ownerID: "party-master", targetID: "party-worker"}) {
		t.Fatalf("unexpected stop call: %#v", actions.stopCalls[0])
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

func renderTrackerANSI(style lipgloss.Style, text string) string {
	r := lipgloss.NewRenderer(io.Discard)
	r.SetColorProfile(termenv.TrueColor)
	return r.NewStyle().Inherit(style).Render(text)
}

func TestTrackerFooterShowsStopDeleteOutsideMaster(t *testing.T) {
	t.Parallel()

	tm := newTestTracker(SessionInfo{ID: "party-worker", SessionType: "worker"}, TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "party-worker", Title: "current", Status: "active", SessionType: "worker", ParentID: "party-master", IsCurrent: true},
		},
	}, &fakeActions{})

	got := tm.trackerFooter(false, false)
	if !strings.Contains(got, "x/d") {
		t.Fatalf("expected lifecycle keys in non-master footer, got %q", got)
	}
	if !strings.Contains(got, " r ") {
		t.Fatalf("expected relay key in non-master footer, got %q", got)
	}
}

func TestTrackerFooterShowsMasterRelayBroadcastKeys(t *testing.T) {
	t.Parallel()

	tm := newTestTracker(SessionInfo{ID: "party-master"}, TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "party-master", Title: "master", Status: "active", SessionType: "master", IsCurrent: true},
		},
		Current: CurrentSessionDetail{ID: "party-master", SessionType: "master"},
	}, &fakeActions{})

	if got := tm.trackerFooter(false, false); !strings.Contains(got, "r/b") {
		t.Fatalf("expected relay/broadcast keys in master footer, got %q", got)
	}
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
	t.Parallel()

	snapshot := TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "party-current", Title: "current", Status: "active", SessionType: "standalone", IsCurrent: true},
			{ID: "party-other", Title: "other", Status: "active", SessionType: "standalone"},
		},
	}

	tm := newTestTracker(SessionInfo{ID: "party-current"}, snapshot, &fakeActions{})
	view := tm.View()

	// Current session's title is styled with the accent color — verify the
	// escape sequence for the accent color appears in the rendered view.
	styled := currentSessionTitleStyle.Render("current")
	if !strings.Contains(view, styled) {
		t.Fatalf("expected current-session title styled with accent color, got:\n%s", view)
	}
}

func TestTrackerSnippetChangeMarksRowActive(t *testing.T) {
	t.Parallel()

	tm := NewTrackerModel(SessionInfo{ID: "party-current"}, nil, &fakeActions{})
	observedAt := time.Date(2026, time.April, 21, 12, 0, 0, 0, time.UTC)
	tm.applySnapshot(TrackerSnapshot{
		Sessions:   []SessionRow{{ID: "party-current", Status: "active", SessionType: "standalone", Snippet: "⏺ still working"}},
		ObservedAt: observedAt,
	})

	row, ok := tm.selectedSession()
	if !ok {
		t.Fatal("expected selected session")
	}
	if !row.PrimaryActive {
		t.Fatal("expected fresh snippet change to mark the row active")
	}
}

func TestTrackerSnippetChangeExpiresAfterActivityWindow(t *testing.T) {
	t.Parallel()

	tm := NewTrackerModel(SessionInfo{ID: "party-current"}, nil, &fakeActions{})
	observedAt := time.Date(2026, time.April, 21, 12, 0, 0, 0, time.UTC)
	tm.applySnapshot(TrackerSnapshot{
		Sessions:   []SessionRow{{ID: "party-current", Status: "active", SessionType: "standalone", Snippet: "⏺ still working"}},
		ObservedAt: observedAt,
	})
	tm.applySnapshot(TrackerSnapshot{
		Sessions:   []SessionRow{{ID: "party-current", Status: "active", SessionType: "standalone", Snippet: "⏺ still working"}},
		ObservedAt: observedAt.Add(ActivityWindow),
	})

	row, ok := tm.selectedSession()
	if !ok {
		t.Fatal("expected selected session")
	}
	if row.PrimaryActive {
		t.Fatal("expected unchanged snippet to go quiet after the activity window")
	}
}

func TestTrackerSnippetChangeResetsActivityWindow(t *testing.T) {
	t.Parallel()

	tm := NewTrackerModel(SessionInfo{ID: "party-current"}, nil, &fakeActions{})
	observedAt := time.Date(2026, time.April, 21, 12, 0, 0, 0, time.UTC)
	tm.applySnapshot(TrackerSnapshot{
		Sessions:   []SessionRow{{ID: "party-current", Status: "active", SessionType: "standalone", Snippet: "⏺ still working"}},
		ObservedAt: observedAt,
	})
	tm.applySnapshot(TrackerSnapshot{
		Sessions:   []SessionRow{{ID: "party-current", Status: "active", SessionType: "standalone", Snippet: "⏺ still working"}},
		ObservedAt: observedAt.Add(2 * time.Second),
	})
	tm.applySnapshot(TrackerSnapshot{
		Sessions:   []SessionRow{{ID: "party-current", Status: "active", SessionType: "standalone", Snippet: "⏺ moved on"}},
		ObservedAt: observedAt.Add(2500 * time.Millisecond),
	})
	tm.applySnapshot(TrackerSnapshot{
		Sessions:   []SessionRow{{ID: "party-current", Status: "active", SessionType: "standalone", Snippet: "⏺ moved on"}},
		ObservedAt: observedAt.Add(4 * time.Second),
	})

	row, ok := tm.selectedSession()
	if !ok {
		t.Fatal("expected selected session")
	}
	if !row.PrimaryActive {
		t.Fatal("expected later snippet change to reset the activity window")
	}
}

func TestTrackerTypingOnlyChangesDoNotRetriggerActivity(t *testing.T) {
	t.Parallel()

	snippet := strings.Join(filterAgentLinesForTest("⏺ Running tests\n"), "\n")
	typingOnly := strings.Join(filterAgentLinesForTest("⏺ Running tests\n❯ next command\n› partial prompt\n"), "\n")
	if snippet != typingOnly {
		t.Fatalf("expected typing-only pane updates to keep the filtered snippet stable: %q vs %q", snippet, typingOnly)
	}

	tm := NewTrackerModel(SessionInfo{ID: "party-current"}, nil, &fakeActions{})
	observedAt := time.Date(2026, time.April, 21, 12, 0, 0, 0, time.UTC)
	tm.applySnapshot(TrackerSnapshot{
		Sessions:   []SessionRow{{ID: "party-current", Status: "active", SessionType: "standalone", Snippet: snippet}},
		ObservedAt: observedAt,
	})
	tm.applySnapshot(TrackerSnapshot{
		Sessions:   []SessionRow{{ID: "party-current", Status: "active", SessionType: "standalone", Snippet: snippet}},
		ObservedAt: observedAt.Add(ActivityWindow),
	})
	tm.applySnapshot(TrackerSnapshot{
		Sessions:   []SessionRow{{ID: "party-current", Status: "active", SessionType: "standalone", Snippet: typingOnly}},
		ObservedAt: observedAt.Add(ActivityWindow + time.Second),
	})

	row, ok := tm.selectedSession()
	if !ok {
		t.Fatal("expected selected session")
	}
	if row.PrimaryActive {
		t.Fatal("expected typing-only pane updates to keep the activity dot off")
	}
}

func filterAgentLinesForTest(raw string) []string {
	return tmux.FilterAgentLines(raw, 4)
}
