package cmd

import (
	"encoding/json"
	"reflect"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/state"
)

func TestAddChatEntryUpdatesNarrationOnlyForChatKinds(t *testing.T) {
	t.Parallel()

	for _, tc := range []struct {
		kind string
		want string
	}{
		{kind: "say", want: "latest"},
		{kind: "message", want: "latest"},
		{kind: "action", want: "previous"},
		{kind: "status", want: "previous"},
		{kind: "report", want: "previous"},
		{kind: "instructions", want: "previous"},
	} {
		t.Run(tc.kind, func(t *testing.T) {
			t.Parallel()
			pane := state.PaneState{Narration: "previous"}
			addChatEntryAt(&state.StateEvent{Ts: time.Unix(1, 0)}, &pane, tc.kind, "latest", time.Time{})
			if pane.Narration != tc.want {
				t.Fatalf("narration = %q, want %q", pane.Narration, tc.want)
			}
		})
	}
}

func TestHookCastTracksStartsEndsAndClearsForHarnesses(t *testing.T) {
	base := time.Date(2026, 10, 20, 7, 33, 48, 529000000, time.UTC)
	tests := []struct {
		name   string
		start  func(*testing.T, *HookRunner, time.Time)
		end    func(*testing.T, *HookRunner, time.Time)
		clear  func(*testing.T, *HookRunner, time.Time)
		tool   string
		callID string
	}{
		{
			name:   "claude",
			tool:   "Bash",
			callID: "claude-call",
			start: func(t *testing.T, r *HookRunner, now time.Time) {
				r.Now = func() time.Time { return now }
				runHookWithStdin(r, "claude", "tool_start", "qm-cast-claude", map[string]interface{}{"tool_name": "Bash", "tool_use_id": "claude-call"})
			},
			end: func(t *testing.T, r *HookRunner, now time.Time) {
				r.Now = func() time.Time { return now }
				runHookWithStdin(r, "claude", "tool_end", "qm-cast-claude", map[string]interface{}{"tool_name": "Bash", "tool_use_id": "claude-call"})
			},
			clear: func(t *testing.T, r *HookRunner, now time.Time) {
				r.Now = func() time.Time { return now }
				runHookWithStdin(r, "claude", "done", "qm-cast-claude", map[string]interface{}{"last_assistant_message": "done"})
			},
		},
		{
			name: "codex",
			tool: "Bash",
			start: func(t *testing.T, r *HookRunner, now time.Time) {
				r.Now = func() time.Time { return now }
				runHookWithStdin(r, "codex", "tool_start", "qm-cast-codex", map[string]interface{}{"tool_name": "Bash"})
			},
			end: func(t *testing.T, r *HookRunner, now time.Time) {
				r.Now = func() time.Time { return now }
				runHookWithStdin(r, "codex", "tool_end", "qm-cast-codex", map[string]interface{}{"tool_name": "Bash"})
			},
			clear: func(t *testing.T, r *HookRunner, now time.Time) {
				r.Now = func() time.Time { return now }
				runHookWithStdin(r, "codex", "done", "qm-cast-codex", map[string]interface{}{"last_assistant_message": "done"})
			},
		},
		{
			name:   "pi",
			tool:   "bash",
			callID: "pi-call",
			start: func(t *testing.T, r *HookRunner, now time.Time) {
				r.Now = func() time.Time { return now }
				runHookWithStdin(r, "pi", "tool_execution_start", "qm-cast-pi", map[string]interface{}{"tool_name": "bash", "tool_call_id": "pi-call"})
			},
			end: func(t *testing.T, r *HookRunner, now time.Time) {
				r.Now = func() time.Time { return now }
				runHookWithStdin(r, "pi", "tool_execution_end", "qm-cast-pi", map[string]interface{}{"tool_name": "bash", "tool_call_id": "pi-call"})
			},
			clear: func(t *testing.T, r *HookRunner, now time.Time) {
				r.Now = func() time.Time { return now }
				runHookWithStdin(r, "pi", "turn_end", "qm-cast-pi", nil)
			},
		},
		{
			name:   "opencode",
			tool:   "bash",
			callID: "oc-call",
			start: func(t *testing.T, r *HookRunner, now time.Time) {
				r.Now = func() time.Time { return now }
				runOpenCodeHookRaw(r, "qm-cast-opencode", openCodeJSON(t, "tool.execute.before", map[string]interface{}{"tool": "bash", "callID": "oc-call"}))
			},
			end: func(t *testing.T, r *HookRunner, now time.Time) {
				r.Now = func() time.Time { return now }
				runOpenCodeHookRaw(r, "qm-cast-opencode", openCodeJSON(t, "tool.execute.after", map[string]interface{}{"tool": "bash", "callID": "oc-call"}))
			},
			clear: func(t *testing.T, r *HookRunner, now time.Time) {
				r.Now = func() time.Time { return now }
				runOpenCodeHookRaw(r, "qm-cast-opencode", openCodeJSON(t, "session.status", map[string]interface{}{"status": map[string]interface{}{"type": "idle"}}))
			},
		},
	}

	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			r, rec := newTestRunner(t)
			var durations []toolDurationCall
			r.RecordToolDuration = func(agent, tool string, duration time.Duration) error {
				durations = append(durations, toolDurationCall{agent: agent, tool: tool, duration: duration})
				return nil
			}
			tc.start(t, r, base)
			pane := rec.lastState.Panes["primary"]
			if pane.Tool != tc.tool || len(pane.RunningTools) != 1 {
				t.Fatalf("start pane = %+v, want %q running", pane, tc.tool)
			}
			if got := pane.RunningTools[0].CallID; got != tc.callID {
				t.Fatalf("call ID = %q, want %q", got, tc.callID)
			}
			if !pane.RunningTools[0].StartedAt.Equal(base) {
				t.Fatalf("started_at = %s, want %s", pane.RunningTools[0].StartedAt, base)
			}

			tc.end(t, r, base.Add(4*time.Second))
			pane = rec.lastState.Panes["primary"]
			if pane.Tool != "" || len(pane.RunningTools) != 0 {
				t.Fatalf("end pane = %+v, want no running tool", pane)
			}
			wantDurations := []toolDurationCall{{agent: tc.name, tool: tc.tool, duration: 4 * time.Second}}
			if !reflect.DeepEqual(durations, wantDurations) {
				t.Fatalf("recorded durations = %+v, want %+v", durations, wantDurations)
			}

			tc.start(t, r, base)
			tc.clear(t, r, base.Add(time.Second))
			pane = rec.lastState.Panes["primary"]
			if pane.Tool != "" || len(pane.RunningTools) != 0 {
				t.Fatalf("stale clearing left cast = %+v", pane)
			}
		})
	}
}

type toolDurationCall struct {
	agent    string
	tool     string
	duration time.Duration
}

func TestHookCastExcludesClaudeAndCodexSubagents(t *testing.T) {
	for _, agent := range []string{"claude", "codex"} {
		agent := agent
		t.Run(agent, func(t *testing.T) {
			r, rec := newTestRunner(t)
			runHookWithStdin(r, agent, "tool_start", "qm-subagent", map[string]interface{}{
				"agent_id": "child-1", "tool_name": "Bash", "tool_use_id": "call-1",
			})
			if pane := rec.lastState.Panes["primary"]; len(pane.RunningTools) != 0 {
				t.Fatalf("subagent cast was tracked: %+v", pane.RunningTools)
			}
		})
	}
}

func TestHookCastLearnsToolNameFromMatchedStart(t *testing.T) {
	r, rec := newTestRunner(t)
	started := time.Date(2026, 10, 20, 7, 33, 48, 0, time.UTC)
	var recorded toolDurationCall
	r.RecordToolDuration = func(agent, tool string, duration time.Duration) error {
		recorded = toolDurationCall{agent: agent, tool: tool, duration: duration}
		return nil
	}
	r.Now = func() time.Time { return started }
	runHookWithStdin(r, "claude", "tool_start", "qm-cast-no-end-name", map[string]interface{}{
		"tool_name": "Bash", "tool_use_id": "call-1",
	})
	r.Now = func() time.Time { return started.Add(3 * time.Second) }
	runHookWithStdin(r, "claude", "tool_end", "qm-cast-no-end-name", map[string]interface{}{
		"tool_use_id": "call-1",
	})
	if pane := rec.lastState.Panes["primary"]; len(pane.RunningTools) != 0 {
		t.Fatalf("tool end left cast: %+v", pane.RunningTools)
	}
	if recorded != (toolDurationCall{agent: "claude", tool: "Bash", duration: 3 * time.Second}) {
		t.Fatalf("recorded duration = %+v", recorded)
	}
}

func TestOpenCodeToolCallIDParsesBothEventShapes(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name       string
		properties map[string]interface{}
		want       string
	}{
		{name: "direct", properties: map[string]interface{}{"callID": "call-1"}, want: "call-1"},
		{name: "nested", properties: map[string]interface{}{"call": map[string]interface{}{"id": "call-2"}}, want: "call-2"},
		{name: "missing", properties: map[string]interface{}{}, want: ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			got := openCodeToolCallID(openCodeEvent{Properties: tc.properties})
			if got != tc.want {
				t.Fatalf("call ID = %q, want %q", got, tc.want)
			}
		})
	}
}

func openCodeJSON(t *testing.T, eventType string, properties map[string]interface{}) []byte {
	t.Helper()
	data, err := json.Marshal(openCodeHookPayload{Event: openCodeEvent{Type: eventType, Properties: properties}})
	if err != nil {
		t.Fatalf("marshal OpenCode event: %v", err)
	}
	return data
}
