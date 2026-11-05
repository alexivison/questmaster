package cmd

import (
	"context"
	"testing"

	"github.com/alexivison/questmaster/internal/message"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
)

const compactActivity = "Final answer before compaction"

func sessionStartSourcePayload(source interface{}) map[string]interface{} {
	payload := map[string]interface{}{"session_id": "claude-session"}
	if source != nil {
		payload["source"] = source
	}
	return payload
}

func TestHookClaudeSessionStartSourceDecidesState(t *testing.T) {
	for _, tc := range []struct {
		name         string
		prevState    string
		source       interface{}
		wantState    string
		wantActivity string
	}{
		{"compact keeps done", "done", "compact", "done", compactActivity},
		{"compact keeps blocked", "blocked", "compact", "blocked", compactActivity},
		{"compact keeps working", "working", "compact", "working", compactActivity},
		{"resume from done starts", "done", "resume", "starting", "started"},
		{"clear from done starts", "done", "clear", "starting", "started"},
		{"startup from empty starts", "", "startup", "starting", "started"},
		{"absent source from done starts", "done", nil, "starting", "started"},
		{"unknown source from done starts", "done", "something-new", "starting", "started"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r, rec := newTestRunner(t)
			if tc.prevState != "" {
				rec.lastState = &state.SessionState{
					SessionID: "qm-abc",
					Version:   state.SchemaVersion,
					Panes: map[string]state.PaneState{
						"agent": {Role: "agent", Agent: "claude", State: tc.prevState, Activity: compactActivity},
					},
				}
			}

			stderr := runHookWithStdin(r, "claude", "starting", "qm-abc", sessionStartSourcePayload(tc.source))
			if stderr != "" {
				t.Errorf("stderr: %q", stderr)
			}
			pane := rec.lastState.Panes["agent"]
			if pane.State != tc.wantState {
				t.Errorf("state = %q, want %q", pane.State, tc.wantState)
			}
			if pane.Activity != tc.wantActivity {
				t.Errorf("activity = %q, want %q", pane.Activity, tc.wantActivity)
			}
		})
	}
}

func TestHookCodexSessionStartSourceDecidesState(t *testing.T) {
	for _, tc := range []struct {
		name      string
		prevState string
		source    interface{}
		wantState string
	}{
		{"compact keeps done", "done", "compact", "done"},
		{"resume from done starts", "done", "resume", "starting"},
		{"startup from empty starts", "", "startup", "starting"},
		{"absent source from done starts", "done", nil, "starting"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r, rec := newTestRunner(t)
			if tc.prevState != "" {
				rec.lastState = &state.SessionState{
					SessionID: "qm-abc",
					Version:   state.SchemaVersion,
					Panes: map[string]state.PaneState{
						"agent": {Role: "agent", Agent: "codex", State: tc.prevState, Activity: compactActivity},
					},
				}
			}

			stderr := runHookWithStdin(r, "codex", "starting", "qm-abc", sessionStartSourcePayload(tc.source))
			if stderr != "" {
				t.Errorf("stderr: %q", stderr)
			}
			if got := rec.lastState.Panes["agent"].State; got != tc.wantState {
				t.Errorf("state = %q, want %q", got, tc.wantState)
			}
		})
	}
}

// notifyTmuxRunner stands in for tmux so message.Notify can reach its send
// path: the recipient is alive, no client is typing, and no native socket
// exists under the temporary state root.
type notifyTmuxRunner struct {
	sendKeys int
}

func (r *notifyTmuxRunner) Run(_ context.Context, args ...string) (string, error) {
	switch args[0] {
	case "list-panes":
		return "0 0 agent", nil
	case "display-message":
		return "0", nil
	case "send-keys":
		if args[len(args)-1] != "Enter" {
			r.sendKeys++
		}
	}
	return "", nil
}

// A Claude worker that finishes its turn and is then compacted while idle
// must still receive a PR alert. The alert path is the production one: the
// Stop and SessionStart hooks write state.json and Notify reads it back.
func TestHookClaudeCompactionWhileDoneStillReceivesAlert(t *testing.T) {
	root := t.TempDir()
	t.Setenv("QUESTMASTER_STATE_ROOT", root)
	store := state.OpenStore(root)
	const sessionID = "qm-compact"
	if err := store.Create(state.Manifest{SessionID: sessionID, Agents: []state.AgentManifest{{Name: "claude", Role: "agent"}}}); err != nil {
		t.Fatalf("create manifest: %v", err)
	}
	r := newHookRunner(store, &tmuxEnvStub{})

	runHookWithStdin(r, "claude", "done", sessionID, map[string]interface{}{"last_assistant_message": compactActivity})
	runHookWithStdin(r, "claude", "starting", sessionID, sessionStartSourcePayload("compact"))

	ss, err := state.LoadSessionStateAt(root, sessionID)
	if err != nil {
		t.Fatalf("load state: %v", err)
	}
	if got := ss.Panes["agent"].State; got != "done" {
		t.Fatalf("state after compaction = %q, want done", got)
	}

	runner := &notifyTmuxRunner{}
	got, err := message.NewService(store, tmux.NewClient(runner)).Notify(context.Background(), sessionID, "[PR owner/repo#12] approved")
	if err != nil {
		t.Fatalf("notify: %v", err)
	}
	if got != message.DeliverySubmitted || runner.sendKeys == 0 {
		t.Fatalf("notify = %q with %d send-keys, want %q delivered", got, runner.sendKeys, message.DeliverySubmitted)
	}
}
