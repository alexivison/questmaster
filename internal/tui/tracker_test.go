package tui

import (
	"context"
	"fmt"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
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
	tm.height = 24
	tm.refreshSessions()
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
			{ID: "party-1230", Title: "Project Alpha", Cwd: "/tmp/project-alpha", Status: "active", SessionType: "master", WorkerCount: 2, PrimaryAgent: "claude", PrimaryState: "waiting", IsCurrent: true},
			{ID: "party-1231", Title: "fix-auth", Cwd: "/tmp/fix-auth", Status: "active", SessionType: "worker", ParentID: "party-1230", PrimaryAgent: "claude", PrimaryState: "active", Stage: StageCriticsOK, Snippet: "❯ make test"},
			{ID: "party-1232", Title: "dark-mode", Cwd: "/tmp/dark-mode", Status: "active", SessionType: "worker", ParentID: "party-1230", PrimaryAgent: "codex", HasCompanion: true, CompanionState: string(CompanionIdle), CompanionVerdict: "APPROVED", Snippet: "⏺ review queued"},
			{ID: "party-1236", Title: "solo task", Cwd: "/tmp/solo", Status: "active", SessionType: "standalone", PrimaryAgent: "codex", Stage: StageChecks, Snippet: "❯ npm test"},
		},
		Current: CurrentSessionDetail{
			ID:              "party-1230",
			Title:           "Project Alpha",
			SessionType:     "master",
			Cwd:             "~/Code/project-b",
			WorkerCount:     2,
			PrimaryAgent:    "claude",
			PrimaryState:    "waiting",
			CompanionName:   "codex",
			CompanionStatus: CompanionStatus{State: CompanionIdle, Verdict: "APPROVED", Mode: "review", Target: "worker"},
		},
	}

	tm := newTestTracker(SessionInfo{ID: "party-1230", SessionType: "master"}, snapshot, &fakeActions{})
	view := tm.View()

	for _, needle := range []string{"Project Alpha", "fix-auth", "dark-mode", "solo task"} {
		if !strings.Contains(view, needle) {
			t.Fatalf("expected %q in view, got:\n%s", needle, view)
		}
	}
	for _, needle := range []string{"party-1231", "/tmp/fix-auth"} {
		if !strings.Contains(view, needle) {
			t.Fatalf("expected secondary row detail %q in view, got:\n%s", needle, view)
		}
	}
	for _, needle := range []string{"❯ make test", "⏺ review queued", "❯ npm test"} {
		if !strings.Contains(view, needle) {
			t.Fatalf("expected snippet %q in view, got:\n%s", needle, view)
		}
	}
	// Status dots should be present for active sessions.
	if !strings.Contains(view, "●") {
		t.Fatalf("expected status dot in view, got:\n%s", view)
	}
	if !strings.Contains(view, "│ party-1230") {
		t.Fatalf("expected master connector on metadata row, got:\n%s", view)
	}
	if !strings.Contains(view, "│ party-1231") {
		t.Fatalf("expected worker connector on metadata row, got:\n%s", view)
	}
	if !strings.Contains(view, "●") {
		t.Fatalf("expected status dots in view, got:\n%s", view)
	}
	if !strings.Contains(view, "│") {
		t.Fatalf("expected worker glyph in view, got:\n%s", view)
	}
}

func TestTrackerViewShowsCurrentSessionDetail(t *testing.T) {
	t.Parallel()

	snapshot := TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "party-2001", Title: "bugfix", Status: "active", SessionType: "worker", ParentID: "party-master", PrimaryAgent: "codex", CompanionVerdict: "APPROVED", Snippet: "❯ fix lint", IsCurrent: true},
		},
		Current: CurrentSessionDetail{
			ID:              "party-2001",
			Title:           "bugfix",
			SessionType:     "worker",
			Cwd:             "~/Code/project",
			PrimaryAgent:    "codex",
			CompanionName:   "codex",
			CompanionStatus: CompanionStatus{State: CompanionIdle, Verdict: "APPROVED", Mode: "review", Target: "main"},
			Evidence: []EvidenceEntry{
				{Type: "code-critic", Result: "APPROVED"},
				{Type: "minimizer", Result: "APPROVED"},
			},
		},
	}

	tm := newTestTracker(SessionInfo{ID: "party-2001", SessionType: "worker"}, snapshot, &fakeActions{})
	view := tm.View()

	for _, needle := range []string{"companion: codex (idle, APPROVED, mode=review, target=main)", "evidence:", "code-critic", "─"} {
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
	if strings.Index(view, "companion:") > strings.Index(view, "> │ bugfix") {
		t.Fatalf("expected current-session detail above the session list, got:\n%s", view)
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
	tm := newTestTracker(SessionInfo{ID: "party-master", SessionType: "master"}, TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "party-master", Title: "master", Status: "active", SessionType: "master", IsCurrent: true},
			{ID: "party-worker", Title: "worker", Status: "active", SessionType: "worker", ParentID: "party-master"},
		},
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

func TestTrackerUpdateRelayIgnoredOutsideCurrentMaster(t *testing.T) {
	t.Parallel()

	actions := &fakeActions{}
	tm := newTestTracker(SessionInfo{ID: "party-worker", SessionType: "worker"}, TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "party-master", Title: "master", Status: "active", SessionType: "master"},
			{ID: "party-other-worker", Title: "worker", Status: "active", SessionType: "worker", ParentID: "party-master"},
			{ID: "party-worker", Title: "current", Status: "active", SessionType: "worker", ParentID: "party-master", IsCurrent: true},
		},
	}, actions)
	tm.cursor = 1

	tm, _ = tm.Update(keyMsg('r'))
	if tm.mode != trackerModeNormal {
		t.Fatalf("expected relay to stay disabled, got mode %v", tm.mode)
	}
	if len(actions.relayCalls) != 0 {
		t.Fatalf("expected no relay calls, got %#v", actions.relayCalls)
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

func TestTrackerFooterShowsStopDeleteOutsideMaster(t *testing.T) {
	t.Parallel()

	tm := newTestTracker(SessionInfo{ID: "party-worker", SessionType: "worker"}, TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "party-worker", Title: "current", Status: "active", SessionType: "worker", ParentID: "party-master", IsCurrent: true},
		},
	}, &fakeActions{})

	if got := tm.trackerFooter(false, false); !strings.Contains(got, "x/d") {
		t.Fatalf("expected lifecycle keys in non-master footer, got %q", got)
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
	tm.fetcher = snapshotFetcher(TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "party-current", Title: "current", Status: "active", SessionType: "standalone", IsCurrent: true},
			{ID: "party-other", Title: "other", Status: "active", SessionType: "standalone"},
		},
	})

	tm.refreshSessions()

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

	if !strings.Contains(view, "◀") {
		t.Fatalf("expected current-session indicator ◀ in view, got:\n%s", view)
	}
}
