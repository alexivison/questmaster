package cmd

import (
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/state"
)

func TestHookInactivityClock(t *testing.T) {
	for _, tc := range []struct {
		name, agent, action string
		payload             interface{}
		pane                state.PaneState
	}{
		{
			name: "Claude narration", agent: "claude", action: "say",
			payload: map[string]interface{}{"message_id": "m1", "index": 0, "final": true, "delta": "Checking the output."},
		},
		{
			name: "Codex tool completion with the same display state", agent: "codex", action: "tool_end",
			payload: map[string]interface{}{"tool_name": "Read"},
			pane:    state.PaneState{LastKind: "PostToolUse"},
		},
		{
			name: "Pi batched progress", agent: "pi", action: "batch",
			payload: map[string]interface{}{"events": []interface{}{
				map[string]interface{}{"action": "progress", "payload": map[string]interface{}{"progress": "Checking the output"}},
			}},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			root := t.TempDir()
			t.Setenv(state.StateRootEnv, root)
			r, _ := newTestRunner(t)
			r.LoadState = state.LoadSessionState
			r.UpdateAndLog = state.UpdateAndLogWithEvents
			r.UpdateAndLogEvents = state.UpdateAndLogBatch
			now := r.Now()
			prior := now.Add(-time.Hour)
			const id = "qm-inactivity"
			if err := state.UpdateAndLogAt(root, id, &state.StateEvent{Ts: prior, Action: "seed"}, func(ss *state.SessionState) bool {
				pane := tc.pane
				pane.Agent, pane.Role, pane.State = tc.agent, "agent", "working"
				pane.LastEvent, pane.WorkingSince = prior, prior
				ss.Panes["agent"] = pane
				return true
			}); err != nil {
				t.Fatal(err)
			}
			if err := state.MarkInactivityAlertedAt(t.Context(), root, id, prior); err != nil {
				t.Fatal(err)
			}
			if stderr := runHookWithStdin(r, tc.agent, tc.action, id, tc.payload); stderr != "" {
				t.Fatal(stderr)
			}
			ss, err := state.LoadSessionStateAt(root, id)
			if err != nil || ss == nil {
				t.Fatalf("load hook state: %v", err)
			}
			pane := ss.Panes["agent"]
			if !pane.WorkActivityAt().Equal(now) || pane.InactivityAlerted {
				t.Fatalf("activity = %v, alerted = %v, want %v and false", pane.WorkActivityAt(), pane.InactivityAlerted, now)
			}
			if !pane.WorkingSince.Equal(prior) {
				t.Fatalf("the working duration was reset to %v", pane.WorkingSince)
			}
		})
	}
}
