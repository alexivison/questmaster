package cmd

import (
	"context"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/state"
)

func TestHookBlockedEpisodesAcrossHarnesses(t *testing.T) {
	for _, harness := range []string{"claude", "codex", "codex async", "pi", "opencode"} {
		for _, combined := range []bool{false, true} {
			name := "fallback/"
			if combined {
				name = "combined/"
			}
			t.Run(name+harness, func(t *testing.T) {
				r, rec := newTestRunner(t)
				root := t.TempDir()
				id := uniqueOpenCodeRuntimeID(t, "qm-blocked-episode")
				if combined {
					r.LoadState = func(id string) (*state.SessionState, error) { return state.LoadSessionStateAt(root, id) }
					r.UpdateAndLog = func(ctx context.Context, id string, ev *state.StateEvent, mutate func(*state.SessionState) bool, extra func(*state.StateEvent) []*state.StateEvent) error {
						return state.UpdateAndLogWithEventsAt(ctx, root, id, ev, mutate, extra)
					}
				}
				pane := func() state.PaneState {
					t.Helper()
					if !combined {
						return rec.lastState.Panes["agent"]
					}
					ss, err := state.LoadSessionStateAt(root, id)
					if err != nil || ss == nil {
						t.Fatalf("load hook state: %v", err)
					}
					return ss.Panes["agent"]
				}
				now := r.Now()
				r.Now = func() time.Time { return now }
				call := func(agent, action string, payload interface{}) {
					t.Helper()
					if stderr := runHookWithStdin(r, agent, action, id, payload); stderr != "" {
						t.Fatal(stderr)
					}
				}
				var ask, repeat, resume func()
				switch harness {
				case "claude":
					ask = func() {
						call("claude", "tool_start", map[string]interface{}{"tool_name": "AskUserQuestion", "tool_input": map[string]interface{}{"questions": []interface{}{map[string]interface{}{"question": "Continue?"}}}})
					}
					repeat = func() {
						call("claude", "blocked", map[string]interface{}{"message": "Claude needs your permission to use AskUserQuestion"})
					}
					resume = func() { call("claude", "working", map[string]interface{}{"prompt": "Continue"}) }
				case "codex", "codex async":
					tool := "request_user_input"
					if harness == "codex async" {
						tool = "request_user_input_async"
					}
					ask = func() { call("codex", "tool_start", map[string]interface{}{"tool_name": tool}) }
					repeat = ask
					if harness == "codex async" {
						repeat = func() {
							call("codex", "tool_end", map[string]interface{}{"tool_name": tool})
							call("codex", "done", map[string]interface{}{})
						}
					}
					resume = func() { call("codex", "working", map[string]interface{}{}) }
				case "pi":
					ask = func() { call("pi", "waiting_for_user", map[string]interface{}{"prompt": "Continue?"}) }
					repeat = ask
					resume = func() { call("pi", "ui_prompt_end", map[string]interface{}{"busy": true}) }
				case "opencode":
					openCodeHookEvent(t, r, id, "session.created", map[string]interface{}{"info": map[string]interface{}{"id": "ses_blocked"}})
					ask = func() {
						openCodeHookEvent(t, r, id, "question.asked", map[string]interface{}{"sessionID": "ses_blocked"})
					}
					repeat = func() {
						openCodeHookEvent(t, r, id, "session.status", map[string]interface{}{"sessionID": "ses_blocked", "status": map[string]interface{}{"type": "busy"}})
					}
					resume = func() {
						openCodeHookEvent(t, r, id, "question.replied", map[string]interface{}{"sessionID": "ses_blocked"})
					}
				}
				ask()
				first := pane().BlockedSince
				if first.IsZero() || pane().BlockedAlerted {
					t.Fatalf("new blocked episode = %+v", pane())
				}
				if combined {
					if err := state.MarkBlockedAlertedAt(t.Context(), root, id, first); err != nil {
						t.Fatal(err)
					}
				} else {
					p := rec.lastState.Panes["agent"]
					p.BlockedAlerted = true
					rec.lastState.Panes["agent"] = p
				}
				now = now.Add(time.Second)
				repeat()
				if p := pane(); !p.BlockedSince.Equal(first) || !p.BlockedAlerted {
					t.Fatalf("repeat lost the episode acknowledgement: %+v", p)
				}
				resume()
				if p := pane(); !p.BlockedSince.IsZero() || p.BlockedAlerted {
					t.Fatalf("resuming retained a pending block: %+v", p)
				}
				now = now.Add(time.Second)
				ask()
				if p := pane(); !p.BlockedSince.After(first) || p.BlockedAlerted {
					t.Fatalf("new block reused the old acknowledgement: %+v", p)
				}
			})
		}
	}
}

func TestPiBatchTracksEachBlockedEpisode(t *testing.T) {
	r, rec := newTestRunner(t)
	const id = "qm-batch-blocked"
	runHookWithStdin(r, "pi", "waiting_for_user", id, map[string]interface{}{"prompt": "First?"})
	pane := rec.lastState.Panes["agent"]
	first := pane.BlockedSince
	pane.BlockedAlerted = true
	rec.lastState.Panes["agent"] = pane
	now := r.Now().Add(time.Minute)
	r.Now = func() time.Time { return now }
	stderr := runHookWithStdin(r, "pi", "batch", id, map[string]interface{}{"events": []interface{}{
		map[string]interface{}{"action": "ui_prompt_end", "payload": map[string]interface{}{"busy": true}},
		map[string]interface{}{"action": "waiting_for_user", "payload": map[string]interface{}{"prompt": "Second?"}},
	}})
	if stderr != "" {
		t.Fatal(stderr)
	}
	if pane := rec.lastState.Panes["agent"]; !pane.BlockedSince.After(first) || pane.BlockedAlerted {
		t.Fatalf("batch failed to distinguish its new blocked episode: %+v", pane)
	}
}
