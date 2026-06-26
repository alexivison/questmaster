//go:build linux || darwin

package runtime

import (
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/quests/gate"
	"github.com/alexivison/questmaster/internal/state"
)

func TestSnapshotJoinsSessionsActivityLoopAndSidecar(t *testing.T) {
	root := t.TempDir()
	t.Setenv(state.StateRootEnv, root)

	store := state.OpenStore(root)
	mustCreate(t, store, "qm-alpha", "claude")
	mustCreate(t, store, "qm-beta", "codex")
	mustStamp(t, "qm-alpha", "Q-1")
	mustStamp(t, "qm-beta", "Q-1")

	workingSince := time.Now().UTC().Add(-2 * time.Minute)
	setPane(t, "qm-alpha", state.PaneState{
		Role: "primary", Agent: "claude", State: "working",
		WorkingSince: workingSince, LastEvent: workingSince,
	})
	blockedAt := time.Now().UTC().Add(-30 * time.Second)
	setPane(t, "qm-beta", state.PaneState{
		Role: "primary", Agent: "codex", State: "blocked", LastEvent: blockedAt,
	})

	if err := state.ArmQuestLoop("qm-beta", time.Now(), false, state.QuestLoopOwnerForeground); err != nil {
		t.Fatalf("arm loop: %v", err)
	}
	if err := state.UpdateQuestLoop("qm-beta", 2, "fail", state.QuestLoopPhaseChecking); err != nil {
		t.Fatalf("update loop: %v", err)
	}

	ranAt := time.Now().UTC().Add(-time.Minute)
	sidecar := gate.NewSidecar(t.TempDir())
	if err := sidecar.Save("Q-1", []gate.Result{{Gate: "tests", Status: gate.StatusFail, RanAt: ranAt}}); err != nil {
		t.Fatalf("sidecar save: %v", err)
	}
	if err := sidecar.Save("Q-2", []gate.Result{{Gate: "ci", Status: gate.StatusPass, RanAt: ranAt}}); err != nil {
		t.Fatalf("sidecar save: %v", err)
	}

	now := time.Now().UTC()
	snap := Snapshot(sidecar, []string{"Q-1", "Q-2"}, now)

	rt := snap["Q-1"]
	if len(rt.Sessions) != 2 || rt.Sessions[0] != "qm-alpha" || rt.Sessions[1] != "qm-beta" {
		t.Fatalf("sessions = %v, want [qm-alpha qm-beta]", rt.Sessions)
	}
	if !rt.ObservedAt.Equal(now) {
		t.Errorf("ObservedAt = %v, want %v", rt.ObservedAt, now)
	}
	if len(rt.Adventurers) != 2 {
		t.Fatalf("adventurers = %d, want 2", len(rt.Adventurers))
	}
	alpha, beta := rt.Adventurers[0], rt.Adventurers[1]
	if alpha.Agent != "claude" || alpha.State != "working" || !alpha.Since.Equal(workingSince) {
		t.Errorf("alpha = %+v, want claude/working since %v", alpha, workingSince)
	}
	if beta.State != "blocked" || !beta.Since.Equal(blockedAt) {
		t.Errorf("beta = %+v, want blocked since %v", beta, blockedAt)
	}
	if beta.Loop == nil || beta.Loop.Iterations != 2 || beta.Loop.LastVerdict != "fail" || beta.Loop.Phase != state.QuestLoopPhaseChecking {
		t.Errorf("beta loop = %+v, want i2 fail checking", beta.Loop)
	}
	// The loop session's agent names the quest-level agent; the quest-level
	// loop is the armed session's marker.
	if rt.Agent != "codex" {
		t.Errorf("runtime agent = %q, want codex (the loop session's)", rt.Agent)
	}
	if rt.Loop == nil || rt.Loop.SessionID != "qm-beta" {
		t.Errorf("runtime loop = %+v, want qm-beta's marker", rt.Loop)
	}
	if rt.Gates["tests"] != "fail" {
		t.Errorf("gates = %v, want tests fail", rt.Gates)
	}
	if got := rt.GatesAt["tests"]; !got.Equal(ranAt) {
		t.Errorf("gate ran-at = %v, want %v", got, ranAt)
	}

	// An unattached quest still carries its recorded sidecar verdicts.
	rt2 := snap["Q-2"]
	if len(rt2.Sessions) != 0 || len(rt2.Adventurers) != 0 {
		t.Errorf("Q-2 should be unattached, got %v", rt2.Sessions)
	}
	if rt2.Gates["ci"] != "pass" {
		t.Errorf("Q-2 gates = %v, want ci pass", rt2.Gates)
	}
}

func TestSnapshotEmptyStateRoot(t *testing.T) {
	t.Setenv(state.StateRootEnv, t.TempDir())
	snap := Snapshot(nil, []string{"Q-1"}, time.Now())
	rt := snap["Q-1"]
	if rt.Attached() || rt.Loop != nil || rt.Gates != nil {
		t.Fatalf("empty root should derive an empty runtime, got %+v", rt)
	}
}

func TestSnapshotDoesNotFullyDecodeUnwantedQuestSessions(t *testing.T) {
	root := t.TempDir()
	t.Setenv(state.StateRootEnv, root)

	store := state.OpenStore(root)
	mustCreate(t, store, "qm-wanted", "codex")
	mustCreate(t, store, "qm-other", "claude")
	mustStamp(t, "qm-wanted", "Q-1")
	mustStamp(t, "qm-other", "Q-2")

	loaded := map[string]int{}
	oldLoad := loadRuntimeSessionStateAt
	loadRuntimeSessionStateAt = func(root, sid string) (*state.SessionState, error) {
		loaded[sid]++
		return state.LoadSessionStateAt(root, sid)
	}
	t.Cleanup(func() { loadRuntimeSessionStateAt = oldLoad })

	snap := Snapshot(nil, []string{"Q-1"}, time.Now())
	if got := snap["Q-1"].Sessions; len(got) != 1 || got[0] != "qm-wanted" {
		t.Fatalf("Q-1 sessions = %v, want [qm-wanted]", got)
	}
	if loaded["qm-wanted"] != 1 {
		t.Fatalf("wanted session full loads = %d, want 1", loaded["qm-wanted"])
	}
	if loaded["qm-other"] != 0 {
		t.Fatalf("unwanted session full loads = %d, want 0", loaded["qm-other"])
	}
}

func TestLoopRuntimeNilMarker(t *testing.T) {
	if got := LoopRuntime("qm-x", nil); got != nil {
		t.Fatalf("nil marker should map to nil, got %+v", got)
	}
	got := LoopRuntime("qm-x", &state.QuestLoopState{Iterations: 3, LastVerdict: "fail", Phase: "waiting"})
	if got.SessionID != "qm-x" || got.Iterations != 3 || got.LastVerdict != "fail" || got.Phase != "waiting" {
		t.Fatalf("mapped marker = %+v", got)
	}
}

func mustCreate(t *testing.T, store *state.Store, sid, agentName string) {
	t.Helper()
	if err := store.Create(state.Manifest{
		SessionID: sid,
		Agents:    []state.AgentManifest{{Name: agentName, Role: "primary"}},
	}); err != nil {
		t.Fatalf("create manifest %s: %v", sid, err)
	}
}

func mustStamp(t *testing.T, sid, questID string) {
	t.Helper()
	if err := state.StampQuest(sid, questID); err != nil {
		t.Fatalf("stamp quest on %s: %v", sid, err)
	}
}

func setPane(t *testing.T, sid string, pane state.PaneState) {
	t.Helper()
	err := state.UpdateSessionState(sid, func(ss *state.SessionState) bool {
		ss.Panes["primary"] = pane
		return true
	})
	if err != nil {
		t.Fatalf("set pane on %s: %v", sid, err)
	}
}
