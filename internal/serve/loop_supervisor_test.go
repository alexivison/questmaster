//go:build linux || darwin

package serve

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/quests/quest"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
)

// fakeSessionRunner answers tmux list-sessions from a settable set and responds
// benignly to the other tmux calls the loop might make.
type fakeSessionRunner struct {
	mu       sync.Mutex
	sessions []string
}

func (r *fakeSessionRunner) set(sessions ...string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.sessions = append([]string(nil), sessions...)
}

func (r *fakeSessionRunner) Run(_ context.Context, args ...string) (string, error) {
	if len(args) == 0 {
		return "", &tmux.ExitError{Code: 1}
	}
	switch args[0] {
	case "list-sessions":
		r.mu.Lock()
		defer r.mu.Unlock()
		out := ""
		for i, s := range r.sessions {
			if i > 0 {
				out += "\n"
			}
			out += s
		}
		return out, nil
	case "has-session", "list-panes", "display-message", "send-keys":
		return "0 1 primary", nil
	default:
		return "", &tmux.ExitError{Code: 1}
	}
}

func setupSupervisorSession(t *testing.T, sessionID, questID string, gates []quest.Gate) (*state.Store, *fakeSessionRunner) {
	t.Helper()
	t.Setenv(quest.HomeEnv, t.TempDir())
	root := t.TempDir()
	t.Setenv(state.StateRootEnv, root)
	store := state.OpenStore(root)

	q := &quest.Quest{ID: questID, Title: questID, Summary: "summary", Status: quest.StatusActive, Gates: gates}
	if err := quest.DefaultStore().Save(q); err != nil {
		t.Fatalf("save quest: %v", err)
	}
	if err := store.Create(state.Manifest{SessionID: sessionID, Title: "loop", Cwd: t.TempDir()}); err != nil {
		t.Fatalf("create manifest: %v", err)
	}
	if err := state.StampQuest(sessionID, questID); err != nil {
		t.Fatalf("stamp quest: %v", err)
	}

	runner := &fakeSessionRunner{}
	runner.set(sessionID)
	return store, runner
}

func writeDonePaneState(t *testing.T, sessionID string, seq int64) {
	t.Helper()
	if err := state.UpdateSessionState(sessionID, func(ss *state.SessionState) bool {
		if ss.Panes == nil {
			ss.Panes = map[string]state.PaneState{}
		}
		ss.Panes["primary"] = state.PaneState{
			Role:      "primary",
			Agent:     "codex",
			State:     "done",
			Seq:       seq,
			LastEvent: time.Unix(seq, 0).UTC(),
			LastKind:  "test",
		}
		return true
	}); err != nil {
		t.Fatalf("write pane state: %v", err)
	}
}

func eventuallyNoRunning(sv *loopSupervisor, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		sv.mu.Lock()
		n := len(sv.running)
		sv.mu.Unlock()
		if n == 0 {
			return true
		}
		time.Sleep(20 * time.Millisecond)
	}
	return false
}

func supervisorMarker(t *testing.T, sessionID string) *state.QuestLoopState {
	t.Helper()
	ss, err := state.LoadSessionState(sessionID)
	if err != nil {
		t.Fatalf("load session state: %v", err)
	}
	if ss == nil {
		return nil
	}
	return ss.QuestLoop
}

func TestLoopSupervisorArmsThenCancelsOnSessionGone(t *testing.T) {
	const sessionID, questID = "qm-super", "SUPER-1"
	store, runner := setupSupervisorSession(t, sessionID, questID, []quest.Gate{
		{Name: "tests", Type: quest.GateAuto, Check: "cmd:true"},
	})

	sv := newLoopSupervisor(store, tmux.NewClient(runner), time.Now)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sv.reconcile(ctx)

	marker := supervisorMarker(t, sessionID)
	if marker == nil {
		t.Fatal("supervisor did not arm a loop marker for an eligible session")
	}
	if marker.Owner != state.QuestLoopOwnerSupervisor {
		t.Fatalf("marker owner = %q, want %q", marker.Owner, state.QuestLoopOwnerSupervisor)
	}
	if marker.Phase != state.QuestLoopPhaseWaiting {
		t.Fatalf("marker phase = %q, want %q", marker.Phase, state.QuestLoopPhaseWaiting)
	}

	// Session disappears: the supervisor cancels the loop and drops the marker.
	runner.set()
	sv.reconcile(ctx)

	if marker := supervisorMarker(t, sessionID); marker != nil {
		t.Fatalf("marker not cleared after session gone: %+v", marker)
	}
	if !eventuallyNoRunning(sv, 2*time.Second) {
		t.Fatal("running set did not drain after session went away")
	}
}

func TestLoopSupervisorRecordsTerminalPhaseOnGreen(t *testing.T) {
	const sessionID, questID = "qm-green", "GRN-6"
	store, runner := setupSupervisorSession(t, sessionID, questID, []quest.Gate{
		{Name: "tests", Type: quest.GateAuto, Check: "cmd:true"},
	})

	sv := newLoopSupervisor(store, tmux.NewClient(runner), time.Now)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sv.reconcile(ctx) // arms a supervisor marker and starts the loop goroutine

	// Drive done-edges with increasing seq until the loop settles green. The
	// repeated writes are robust against the watcher's high-water seeding race:
	// once the watcher has seeded, the next strictly-newer edge triggers a check,
	// and cmd:true is green on the first run.
	deadline := time.Now().Add(5 * time.Second)
	for seq := int64(1); time.Now().Before(deadline); seq++ {
		writeDonePaneState(t, sessionID, seq)
		if m := supervisorMarker(t, sessionID); m != nil && m.Phase == state.QuestLoopPhaseGreen {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}

	m := supervisorMarker(t, sessionID)
	if m == nil || m.Phase != state.QuestLoopPhaseGreen {
		t.Fatalf("supervised loop did not settle green: %+v", m)
	}
	if !eventuallyNoRunning(sv, 2*time.Second) {
		t.Fatal("running set did not drain after the loop settled")
	}
}

func TestLoopSupervisorRunCancelsAllOnShutdown(t *testing.T) {
	const sessionID, questID = "qm-shutdown", "SHD-7"
	store, runner := setupSupervisorSession(t, sessionID, questID, []quest.Gate{
		{Name: "tests", Type: quest.GateAuto, Check: "cmd:true"},
	})

	sv := newLoopSupervisor(store, tmux.NewClient(runner), time.Now)
	ctx, cancel := context.WithCancel(context.Background())

	runDone := make(chan struct{})
	go func() { sv.Run(ctx, 20*time.Millisecond); close(runDone) }()

	// Wait until the supervisor has armed and started exactly one loop.
	started := false
	for d := time.Now().Add(2 * time.Second); time.Now().Before(d); {
		sv.mu.Lock()
		n := len(sv.running)
		sv.mu.Unlock()
		if n == 1 {
			started = true
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if !started {
		cancel()
		t.Fatal("supervisor did not start a loop")
	}

	cancel()
	select {
	case <-runDone:
	case <-time.After(2 * time.Second):
		t.Fatal("Run did not return after ctx cancel")
	}
	if !eventuallyNoRunning(sv, time.Second) {
		t.Fatal("cancelAll did not drain the running set on shutdown")
	}
}

func TestLoopSupervisorSkipsSuppressedSession(t *testing.T) {
	const sessionID, questID = "qm-suppressed", "SUP-2"
	store, runner := setupSupervisorSession(t, sessionID, questID, []quest.Gate{
		{Name: "tests", Type: quest.GateAuto, Check: "cmd:true"},
	})
	if err := state.SetQuestLoopSuppressed(sessionID, true); err != nil {
		t.Fatalf("suppress: %v", err)
	}

	sv := newLoopSupervisor(store, tmux.NewClient(runner), time.Now)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	sv.reconcile(ctx)

	if marker := supervisorMarker(t, sessionID); marker != nil {
		t.Fatalf("supervisor armed a suppressed session: %+v", marker)
	}
}

func TestLoopSupervisorSkipsToggleOnlyQuest(t *testing.T) {
	const sessionID, questID = "qm-toggleonly", "TOG-3"
	store, runner := setupSupervisorSession(t, sessionID, questID, []quest.Gate{
		{Name: "review", Type: quest.GateToggle, Before: quest.BeforePR},
	})

	sv := newLoopSupervisor(store, tmux.NewClient(runner), time.Now)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	sv.reconcile(ctx)

	if marker := supervisorMarker(t, sessionID); marker != nil {
		t.Fatalf("supervisor armed a quest with no auto gates: %+v", marker)
	}
}

func TestLoopSupervisorLeavesForegroundOwnedMarker(t *testing.T) {
	const sessionID, questID = "qm-foreground", "FG-4"
	store, runner := setupSupervisorSession(t, sessionID, questID, []quest.Gate{
		{Name: "tests", Type: quest.GateAuto, Check: "cmd:true"},
	})
	if err := state.ArmQuestLoop(sessionID, time.Now(), false, state.QuestLoopOwnerForeground); err != nil {
		t.Fatalf("arm foreground marker: %v", err)
	}

	sv := newLoopSupervisor(store, tmux.NewClient(runner), time.Now)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	sv.reconcile(ctx)

	marker := supervisorMarker(t, sessionID)
	if marker == nil || marker.Owner != state.QuestLoopOwnerForeground {
		t.Fatalf("supervisor disturbed a foreground-owned marker: %+v", marker)
	}
}

func TestLoopSupervisorSettlesTerminalMarkerWithoutRestart(t *testing.T) {
	const sessionID, questID = "qm-settled", "SET-5"
	store, runner := setupSupervisorSession(t, sessionID, questID, []quest.Gate{
		{Name: "tests", Type: quest.GateAuto, Check: "cmd:true"},
	})
	// A supervisor marker already settled green must not be restarted.
	if err := state.ArmQuestLoop(sessionID, time.Now(), false, state.QuestLoopOwnerSupervisor); err != nil {
		t.Fatalf("arm: %v", err)
	}
	if err := state.SetQuestLoopPhase(sessionID, state.QuestLoopPhaseGreen); err != nil {
		t.Fatalf("set terminal phase: %v", err)
	}

	sv := newLoopSupervisor(store, tmux.NewClient(runner), time.Now)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	sv.reconcile(ctx)

	marker := supervisorMarker(t, sessionID)
	if marker == nil || marker.Phase != state.QuestLoopPhaseGreen {
		t.Fatalf("settled terminal marker was disturbed: %+v", marker)
	}
	sv.mu.Lock()
	running := len(sv.running)
	sv.mu.Unlock()
	if running != 0 {
		t.Fatalf("supervisor restarted a settled loop: running=%d", running)
	}
}
