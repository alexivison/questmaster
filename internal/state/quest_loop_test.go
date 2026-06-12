//go:build linux || darwin

package state

import (
	"testing"
	"time"
)

func loadMarker(t *testing.T, sid string) *QuestLoopState {
	t.Helper()
	ss, err := LoadSessionState(sid)
	if err != nil {
		t.Fatalf("load session state: %v", err)
	}
	if ss == nil {
		return nil
	}
	return ss.QuestLoop
}

func TestQuestLoopPhaseTransitions(t *testing.T) {
	t.Setenv(StateRootEnv, t.TempDir())
	const sid = "qm-loopphase"

	if err := ArmQuestLoop(sid, time.Now(), false); err != nil {
		t.Fatalf("arm: %v", err)
	}
	if m := loadMarker(t, sid); m == nil || m.Phase != QuestLoopPhaseWaiting {
		t.Fatalf("armed marker = %+v, want phase waiting", m)
	}

	if err := SetQuestLoopPhase(sid, QuestLoopPhaseChecking); err != nil {
		t.Fatalf("set phase: %v", err)
	}
	if m := loadMarker(t, sid); m.Phase != QuestLoopPhaseChecking {
		t.Fatalf("marker phase = %q, want checking", m.Phase)
	}

	if err := UpdateQuestLoop(sid, 1, "fail", QuestLoopPhaseWaiting); err != nil {
		t.Fatalf("update: %v", err)
	}
	m := loadMarker(t, sid)
	if m.Iterations != 1 || m.LastVerdict != "fail" || m.Phase != QuestLoopPhaseWaiting {
		t.Fatalf("marker after iteration = %+v, want i1 fail waiting", m)
	}

	if err := ClearQuestLoop(sid); err != nil {
		t.Fatalf("clear: %v", err)
	}
	// Phase writes on a cleared marker stay advisory no-ops.
	if err := SetQuestLoopPhase(sid, QuestLoopPhasePaused); err != nil {
		t.Fatalf("set phase after clear: %v", err)
	}
	if m := loadMarker(t, sid); m != nil {
		t.Fatalf("marker resurrected by a phase write: %+v", m)
	}
}
