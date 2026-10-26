package cmd

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

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

func TestAddChatEntryCapsNarrationToOneTrackerLine(t *testing.T) {
	t.Parallel()
	pane := state.PaneState{}
	addChatEntryAt(&state.StateEvent{Ts: time.Unix(1, 0)}, &pane, "say", strings.Repeat("a", 250)+"\nmore", time.Time{})
	if utf8.RuneCountInString(pane.Narration) != 180 || !strings.HasSuffix(pane.Narration, "...") || strings.ContainsAny(pane.Narration, "\r\n") {
		t.Fatalf("narration length/newline = %d/%t, want 180/false", utf8.RuneCountInString(pane.Narration), strings.ContainsAny(pane.Narration, "\r\n"))
	}
}

func TestHookCastTracksStartsEndsAndClearsForHarnesses(t *testing.T) {
	base := time.Date(2026, 10, 20, 7, 33, 48, 529000000, time.UTC)
	tests := []struct {
		name       string
		start      func(*testing.T, *HookRunner, time.Time)
		end        func(*testing.T, *HookRunner, time.Time)
		clear      func(*testing.T, *HookRunner, time.Time)
		tool       string
		callID     string
		command    string
		commandKey string
	}{
		{
			name:       "claude",
			tool:       "Bash",
			callID:     "claude-call",
			command:    "FOO=bar go test ./... && sleep 6",
			commandKey: "go test",
			start: func(t *testing.T, r *HookRunner, now time.Time) {
				r.Now = func() time.Time { return now }
				runHookWithStdin(r, "claude", "tool_start", "qm-cast-claude", map[string]interface{}{
					"tool_name": "Bash", "tool_use_id": "claude-call", "tool_input": map[string]interface{}{"command": "FOO=bar go test ./... && sleep 6"},
				})
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
			name:       "codex",
			tool:       "Bash",
			callID:     "codex-call",
			command:    "cd /tmp && /usr/bin/git status --short",
			commandKey: "git status",
			start: func(t *testing.T, r *HookRunner, now time.Time) {
				r.Now = func() time.Time { return now }
				runHookWithStdin(r, "codex", "tool_start", "qm-cast-codex", map[string]interface{}{
					"tool_name": "Bash", "tool_use_id": "codex-call", "tool_input": map[string]interface{}{"command": "cd /tmp && /usr/bin/git status --short"},
				})
			},
			end: func(t *testing.T, r *HookRunner, now time.Time) {
				r.Now = func() time.Time { return now }
				runHookWithStdin(r, "codex", "tool_end", "qm-cast-codex", map[string]interface{}{"tool_name": "Bash", "tool_use_id": "codex-call"})
			},
			clear: func(t *testing.T, r *HookRunner, now time.Time) {
				r.Now = func() time.Time { return now }
				runHookWithStdin(r, "codex", "done", "qm-cast-codex", map[string]interface{}{"last_assistant_message": "done"})
			},
		},
		{
			name:       "pi",
			tool:       "bash",
			callID:     "pi-call",
			command:    "npm run build",
			commandKey: "npm run",
			start: func(t *testing.T, r *HookRunner, now time.Time) {
				r.Now = func() time.Time { return now }
				runHookWithStdin(r, "pi", "tool_execution_start", "qm-cast-pi", map[string]interface{}{
					"tool_name": "bash", "tool_call_id": "pi-call", "args": map[string]interface{}{"command": "npm run build"},
				})
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
			name:       "opencode",
			tool:       "bash",
			callID:     "oc-call",
			command:    "timeout 12 sleep 6",
			commandKey: "sleep",
			start: func(t *testing.T, r *HookRunner, now time.Time) {
				r.Now = func() time.Time { return now }
				runOpenCodeHookRaw(r, "qm-cast-opencode", openCodeJSON(t, "tool.execute.before", map[string]interface{}{
					"tool": "bash", "callID": "oc-call", "args": map[string]interface{}{"command": "timeout 12 sleep 6"},
				}))
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
			r.RecordToolDuration = func(agent, tool, command string, duration time.Duration) error {
				durations = append(durations, toolDurationCall{agent: agent, tool: tool, command: command, duration: duration})
				return nil
			}
			tc.start(t, r, base)
			pane := rec.lastState.Panes["agent"]
			if pane.Tool != tc.tool || len(pane.RunningTools) != 1 {
				t.Fatalf("start pane = %+v, want %q running", pane, tc.tool)
			}
			if got := pane.RunningTools[0].CallID; got != tc.callID {
				t.Fatalf("call ID = %q, want %q", got, tc.callID)
			}
			if got := pane.RunningTools[0].Command; got != tc.commandKey {
				t.Fatalf("command key = %q, want %q (command %q)", got, tc.commandKey, tc.command)
			}
			if !pane.RunningTools[0].StartedAt.Equal(base) {
				t.Fatalf("started_at = %s, want %s", pane.RunningTools[0].StartedAt, base)
			}

			tc.end(t, r, base.Add(4*time.Second))
			pane = rec.lastState.Panes["agent"]
			if pane.Tool != "" || len(pane.RunningTools) != 0 {
				t.Fatalf("end pane = %+v, want no running tool", pane)
			}
			wantDurations := []toolDurationCall{{agent: tc.name, tool: tc.tool, command: tc.commandKey, duration: 4 * time.Second}}
			if !reflect.DeepEqual(durations, wantDurations) {
				t.Fatalf("recorded durations = %+v, want %+v", durations, wantDurations)
			}

			tc.start(t, r, base)
			tc.clear(t, r, base.Add(time.Second))
			pane = rec.lastState.Panes["agent"]
			if pane.Tool != "" || len(pane.RunningTools) != 0 {
				t.Fatalf("stale clearing left cast = %+v", pane)
			}
		})
	}
}

type toolDurationCall struct {
	agent    string
	tool     string
	command  string
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
			if pane := rec.lastState.Panes["agent"]; len(pane.RunningTools) != 0 {
				t.Fatalf("subagent cast was tracked: %+v", pane.RunningTools)
			}
		})
	}
}

func TestHookCastLearnsToolNameFromMatchedStart(t *testing.T) {
	r, rec := newTestRunner(t)
	started := time.Date(2026, 10, 20, 7, 33, 48, 0, time.UTC)
	var recorded toolDurationCall
	r.RecordToolDuration = func(agent, tool, command string, duration time.Duration) error {
		recorded = toolDurationCall{agent: agent, tool: tool, command: command, duration: duration}
		return nil
	}
	r.Now = func() time.Time { return started }
	runHookWithStdin(r, "claude", "tool_start", "qm-cast-no-end-name", map[string]interface{}{
		"tool_name": "Bash", "tool_use_id": "call-1", "tool_input": map[string]interface{}{"command": "go test ./..."},
	})
	r.Now = func() time.Time { return started.Add(3 * time.Second) }
	runHookWithStdin(r, "claude", "tool_end", "qm-cast-no-end-name", map[string]interface{}{
		"tool_use_id": "call-1",
	})
	if pane := rec.lastState.Panes["agent"]; len(pane.RunningTools) != 0 {
		t.Fatalf("tool end left cast: %+v", pane.RunningTools)
	}
	if recorded != (toolDurationCall{agent: "claude", tool: "Bash", command: "go test", duration: 3 * time.Second}) {
		t.Fatalf("recorded duration = %+v", recorded)
	}
}

func TestHookCastSkipsDurationAfterSessionWaitsForInput(t *testing.T) {
	base := time.Date(2026, 10, 20, 7, 33, 48, 529000000, time.UTC)
	tests := []struct {
		name  string
		start func(*testing.T, *HookRunner, time.Time)
		wait  func(*testing.T, *HookRunner, time.Time)
		end   func(*testing.T, *HookRunner, time.Time)
	}{
		{
			name: "claude",
			start: func(t *testing.T, r *HookRunner, now time.Time) {
				r.Now = func() time.Time { return now }
				runHookWithStdin(r, "claude", "tool_start", "qm-cast-wait-claude", map[string]interface{}{
					"tool_name": "Bash", "tool_use_id": "call-1",
				})
			},
			wait: func(t *testing.T, r *HookRunner, now time.Time) {
				r.Now = func() time.Time { return now }
				runHookWithStdin(r, "claude", "blocked", "qm-cast-wait-claude", map[string]interface{}{"message": "Approval needed"})
			},
			end: func(t *testing.T, r *HookRunner, now time.Time) {
				r.Now = func() time.Time { return now }
				runHookWithStdin(r, "claude", "tool_end", "qm-cast-wait-claude", map[string]interface{}{"tool_use_id": "call-1"})
			},
		},
		{
			name: "codex",
			start: func(t *testing.T, r *HookRunner, now time.Time) {
				r.Now = func() time.Time { return now }
				runHookWithStdin(r, "codex", "tool_start", "qm-cast-wait-codex", map[string]interface{}{
					"tool_name": "Bash", "tool_use_id": "call-1",
				})
			},
			wait: func(t *testing.T, r *HookRunner, now time.Time) {
				r.Now = func() time.Time { return now }
				runHookWithStdin(r, "codex", "permission", "qm-cast-wait-codex", map[string]interface{}{})
			},
			end: func(t *testing.T, r *HookRunner, now time.Time) {
				r.Now = func() time.Time { return now }
				runHookWithStdin(r, "codex", "tool_end", "qm-cast-wait-codex", map[string]interface{}{"tool_use_id": "call-1"})
			},
		},
		{
			name: "pi",
			start: func(t *testing.T, r *HookRunner, now time.Time) {
				r.Now = func() time.Time { return now }
				runHookWithStdin(r, "pi", "tool_execution_start", "qm-cast-wait-pi", map[string]interface{}{
					"tool_name": "bash", "tool_call_id": "call-1",
				})
			},
			wait: func(t *testing.T, r *HookRunner, now time.Time) {
				r.Now = func() time.Time { return now }
				runHookWithStdin(r, "pi", "waiting_for_user", "qm-cast-wait-pi", map[string]interface{}{"question": "Continue?"})
			},
			end: func(t *testing.T, r *HookRunner, now time.Time) {
				r.Now = func() time.Time { return now }
				runHookWithStdin(r, "pi", "tool_execution_end", "qm-cast-wait-pi", map[string]interface{}{
					"tool_name": "bash", "tool_call_id": "call-1",
				})
			},
		},
		{
			name: "opencode",
			start: func(t *testing.T, r *HookRunner, now time.Time) {
				r.Now = func() time.Time { return now }
				runOpenCodeHookRaw(r, "qm-cast-wait-opencode", openCodeJSON(t, "tool.execute.before", map[string]interface{}{
					"tool": "bash", "callID": "call-1",
				}))
			},
			wait: func(t *testing.T, r *HookRunner, now time.Time) {
				r.Now = func() time.Time { return now }
				runOpenCodeHookRaw(r, "qm-cast-wait-opencode", openCodeJSON(t, "permission.asked", map[string]interface{}{}))
			},
			end: func(t *testing.T, r *HookRunner, now time.Time) {
				r.Now = func() time.Time { return now }
				runOpenCodeHookRaw(r, "qm-cast-wait-opencode", openCodeJSON(t, "tool.execute.after", map[string]interface{}{
					"tool": "bash", "callID": "call-1",
				}))
			},
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			r, rec := newTestRunner(t)
			var durations []toolDurationCall
			r.RecordToolDuration = func(agent, tool, command string, duration time.Duration) error {
				durations = append(durations, toolDurationCall{agent: agent, tool: tool, command: command, duration: duration})
				return nil
			}
			tc.start(t, r, base)
			tc.wait(t, r, base.Add(time.Second))
			pane := rec.lastState.Panes["agent"]
			if pane.State != "blocked" || len(pane.RunningTools) != 1 || !pane.RunningTools[0].WaitedForInput {
				t.Fatalf("waiting state = %+v, want blocked with tool marked as user wait", pane)
			}

			tc.end(t, r, base.Add(10*time.Second))
			if len(durations) != 0 {
				t.Fatalf("recorded durations after waiting = %+v, want none", durations)
			}
		})
	}
}

func TestHookCastSkipsAskUserToolDurationsInHarnessOrder(t *testing.T) {
	base := time.Date(2026, 10, 20, 7, 33, 48, 529000000, time.UTC)
	type event struct {
		after  time.Duration
		action string
		data   map[string]interface{}
	}
	tests := []struct {
		name    string
		agent   string
		session string
		events  []event
	}{
		{
			name:  "claude AskUserQuestion",
			agent: "claude", session: "qm-cast-ask-claude",
			events: []event{
				{action: "tool_start", data: map[string]interface{}{"tool_name": "AskUserQuestion", "tool_use_id": "call-1"}},
				{after: 90 * time.Second, action: "tool_end", data: map[string]interface{}{"tool_use_id": "call-1"}},
			},
		},
		{
			name:  "codex request_user_input",
			agent: "codex", session: "qm-cast-ask-codex",
			events: []event{
				{action: "tool_start", data: map[string]interface{}{"tool_name": "functions.request_user_input", "tool_use_id": "call-1"}},
				{after: 90 * time.Second, action: "tool_end", data: map[string]interface{}{"tool_use_id": "call-1"}},
			},
		},
		{
			name:  "pi ask_user event order",
			agent: "pi", session: "qm-cast-ask-pi",
			events: []event{
				{action: "agent_start"},
				{after: time.Second, action: "waiting_for_user", data: map[string]interface{}{"prompt": "Continue?"}},
				{after: 2 * time.Second, action: "tool_execution_start", data: map[string]interface{}{"tool_name": "ask_user", "tool_call_id": "call-1"}},
				{after: 92 * time.Second, action: "tool_execution_end", data: map[string]interface{}{"tool_name": "ask_user", "tool_call_id": "call-1"}},
			},
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			r, rec := newTestRunner(t)
			var durations []toolDurationCall
			r.RecordToolDuration = func(agent, tool, command string, duration time.Duration) error {
				durations = append(durations, toolDurationCall{agent: agent, tool: tool, command: command, duration: duration})
				return nil
			}
			for _, event := range tc.events {
				r.Now = func() time.Time { return base.Add(event.after) }
				runHookWithStdin(r, tc.agent, event.action, tc.session, event.data)
				if event.action == "tool_start" || event.action == "tool_execution_start" {
					pane := rec.lastState.Panes["agent"]
					if pane.State != "blocked" || len(pane.RunningTools) != 1 || !pane.RunningTools[0].WaitedForInput {
						t.Fatalf("tool start pane = %+v, want blocked tool marked as user wait", pane)
					}
				}
			}
			if len(durations) != 0 {
				t.Fatalf("recorded durations after ask_user = %+v, want none", durations)
			}
		})
	}
}

func TestToolCommandKeyExtractionByHarness(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name  string
		agent string
		tool  string
		input interface{}
		want  string
	}{
		{name: "claude Bash", agent: "claude", tool: "Bash", input: map[string]interface{}{"command": "go test ./..."}, want: "go test"},
		{name: "codex Bash", agent: "codex", tool: "Bash", input: map[string]interface{}{"command": "git status"}, want: "git status"},
		{name: "codex exec_command", agent: "codex", tool: "exec_command", input: map[string]interface{}{"command": "go test ./..."}, want: "go test"},
		{name: "codex shell", agent: "codex", tool: "shell", input: map[string]interface{}{"command": "sleep 6"}, want: "sleep"},
		{name: "pi bash", agent: "pi", tool: "bash", input: map[string]interface{}{"command": "npm run build"}, want: "npm run"},
		{name: "opencode bash", agent: "opencode", tool: "bash", input: map[string]interface{}{"command": "sleep 6"}, want: "sleep"},
		{name: "non-shell Claude tool", agent: "claude", tool: "Read", input: map[string]interface{}{"command": "go test ./..."}, want: ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			if got := toolCommandKey(tc.agent, tc.tool, tc.input); got != tc.want {
				t.Fatalf("toolCommandKey(%q, %q, %#v) = %q, want %q", tc.agent, tc.tool, tc.input, got, tc.want)
			}
		})
	}
}

func TestOpenCodeToolCallIDUsesPluginShape(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name       string
		properties map[string]interface{}
		want       string
	}{
		{name: "direct", properties: map[string]interface{}{"callID": "call-1"}, want: "call-1"},
		{name: "wrong casing", properties: map[string]interface{}{"callId": "call-2"}, want: ""},
		{name: "nested legacy shape", properties: map[string]interface{}{"call": map[string]interface{}{"id": "call-3"}}, want: ""},
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
