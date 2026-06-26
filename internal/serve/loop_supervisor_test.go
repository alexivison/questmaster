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
