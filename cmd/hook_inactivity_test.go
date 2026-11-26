package cmd

import (
	"strings"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/state"
)

func TestHookInactivityClock(t *testing.T) {
	reasoning := strings.Repeat("Checking the output. ", 5)
	for _, tc := range []struct {
		name, agent, action string
		payload             interface{}
		pane                state.PaneState
		advances            bool
		keepDisplay         bool
	}{
		{
			name: "Claude narration", agent: "claude", action: "say",
			payload:  map[string]interface{}{"message_id": "m1", "index": 0, "final": true, "delta": "Checking the output."},
			advances: true,
		},
		{
			name: "Codex tool completion with the same display state", agent: "codex", action: "tool_end",
			payload:  map[string]interface{}{"tool_name": "Read"},
			pane:     state.PaneState{LastKind: "PostToolUse"},
			advances: true,
		},
		{
			name: "Pi batched progress", agent: "pi", action: "batch",
			payload: map[string]interface{}{"events": []interface{}{
				map[string]interface{}{"action": "progress", "payload": map[string]interface{}{"progress": "Checking the output"}},
			}},
			advances: true,
		},
		{
			name: "OpenCode tool completion", agent: "opencode", action: "event",
			payload: openCodeEvent{Type: "tool.execute.after", Properties: map[string]interface{}{
				"sessionID": "ses_root", "tool": "bash", "callID": "call-1",
			}},
			pane:     state.PaneState{OpenCodeSessionID: "ses_root"},
			advances: true,
		},
		{
			name: "OpenCode reasoning extends beyond the display snippet", agent: "opencode", action: "event",
			payload: openCodeEvent{Type: "message.part.updated", Properties: map[string]interface{}{
				"sessionID": "ses_root", "part": map[string]interface{}{"type": "reasoning", "text": reasoning + "Continuing the check."},
			}},
			pane: state.PaneState{
				OpenCodeSessionID: "ses_root", LastKind: "message.part.updated", Activity: "Thinking: " + truncatePromptLine(reasoning),
			},
			advances:    true,
			keepDisplay: true,
		},
		{
			name: "OpenCode registered child starts a tool", agent: "opencode", action: "event",
			payload: openCodeEvent{Type: "tool.execute.before", Properties: map[string]interface{}{
				"sessionID": "ses_child", "tool": "read", "callID": "child-call",
			}},
			pane: state.PaneState{
				OpenCodeSessionID: "ses_root", LastKind: "tool.execute.before", Activity: "Tool: task", Tool: "task",
				ActiveSubagents: map[string]string{"ses_child": "Explore"},
			},
			advances:    true,
			keepDisplay: true,
		},
		{
			name: "OpenCode unrelated session starts a tool", agent: "opencode", action: "event",
			payload: openCodeEvent{Type: "tool.execute.before", Properties: map[string]interface{}{
				"sessionID": "ses_other", "tool": "read", "callID": "other-call",
			}},
			pane: state.PaneState{
				OpenCodeSessionID: "ses_root", LastKind: "tool.execute.before", Activity: "Tool: task", Tool: "task",
				ActiveSubagents: map[string]string{"ses_child": "Explore"},
			},
			keepDisplay: true,
		},
		{
			name: "OpenCode busy status", agent: "opencode", action: "event",
			payload: openCodeEvent{Type: "session.status", Properties: map[string]interface{}{
				"sessionID": "ses_root", "status": map[string]interface{}{"type": "busy"},
			}},
			pane: state.PaneState{OpenCodeSessionID: "ses_root", LastKind: "tool.execute.after"},
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
			want := prior
			if tc.advances {
				want = now
			}
			pane := ss.Panes["agent"]
			if !pane.WorkActivityAt().Equal(want) || pane.InactivityAlerted != !tc.advances {
				t.Fatalf("activity = %v, alerted = %v, want %v and %v", pane.WorkActivityAt(), pane.InactivityAlerted, want, !tc.advances)
			}
			if !pane.WorkingSince.Equal(prior) {
				t.Fatalf("the working duration was reset to %v", pane.WorkingSince)
			}
			if tc.keepDisplay && (pane.State != "working" || pane.Activity != tc.pane.Activity || pane.Tool != tc.pane.Tool ||
				pane.LastKind != tc.pane.LastKind || pane.OpenCodeSessionID != tc.pane.OpenCodeSessionID) {
				t.Fatalf("the hook changed the parent display: %+v", pane)
			}
		})
	}
}

func TestOpenCodeChildWorkPreservesParentBlock(t *testing.T) {
	t.Parallel()
	r, rec := newParallelHookRunner()
	const id = "qm-blocked-parent"
	blockedAt := r.Now().Add(-time.Minute)
	rec.lastState = &state.SessionState{SessionID: id, Panes: map[string]state.PaneState{
		"agent": {
			Agent: "opencode", State: "blocked", OpenCodeSessionID: "ses_root",
			Activity: "Question: Continue?", BlockedSince: blockedAt, BlockedAlerted: true,
			ActiveSubagents: map[string]string{"ses_child": "Explore"},
		},
	}}
	openCodeHookEvent(t, r, id, "tool.execute.before", map[string]interface{}{
		"sessionID": "ses_child", "tool": "read", "callID": "child-call",
	})
	pane := rec.lastState.Panes["agent"]
	if pane.State != "blocked" || pane.Activity != "Question: Continue?" || !pane.BlockedSince.Equal(blockedAt) ||
		!pane.BlockedAlerted || !pane.LastWorkActivity.IsZero() || len(rec.events) != 0 {
		t.Fatalf("child tool changed the blocked parent's state or feed: %+v, events=%v", pane, rec.events)
	}
}
