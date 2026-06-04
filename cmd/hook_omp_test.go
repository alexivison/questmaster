package cmd

import "testing"

// TestHookOmpReusesPiHandler exercises the omp route through handlePiLike:
// the same Pi event vocabulary must drive state transitions while recording
// "omp" as the pane's agent identity.
func TestHookOmpReusesPiHandler(t *testing.T) {
	r, rec := newTestRunner(t)

	runHookWithStdin(r, "omp", "agent_start", "qm-omp", map[string]interface{}{
		"session_file": "/h/.omp/agent/sessions/--r--/2026-05-30T12-00-00-000Z_1f9d2a6b9c0d1234.jsonl",
		"prompt":       "fix the parser",
	})
	pane := rec.lastState.Panes["primary"]
	if pane.Agent != "omp" {
		t.Fatalf("pane agent: got %q, want omp", pane.Agent)
	}
	if pane.State != "starting" {
		t.Fatalf("agent_start state: got %q, want starting", pane.State)
	}
	if pane.SessionFile == "" {
		t.Fatalf("session_file should be captured for resume")
	}

	runHookWithStdin(r, "omp", "tool_execution_start", "qm-omp", map[string]interface{}{
		"toolName": "Bash",
		"input":    map[string]interface{}{"command": "go test ./..."},
	})
	pane = rec.lastState.Panes["primary"]
	if pane.State != "working" || pane.Tool != "Bash" {
		t.Fatalf("tool_execution_start: state=%q tool=%q", pane.State, pane.Tool)
	}
	if pane.Activity != "Bash: go test ./..." {
		t.Fatalf("tool activity: got %q", pane.Activity)
	}

	runHookWithStdin(r, "omp", "agent_end", "qm-omp", map[string]interface{}{
		"text": "All tests pass.",
	})
	pane = rec.lastState.Panes["primary"]
	if pane.State != "done" {
		t.Fatalf("agent_end state: got %q, want done", pane.State)
	}
	if pane.Activity != "All tests pass." {
		t.Fatalf("agent_end activity: got %q", pane.Activity)
	}

	// Every recorded event must carry the omp identity.
	for _, ev := range rec.events {
		if ev.Agent != "omp" {
			t.Fatalf("event agent: got %q, want omp", ev.Agent)
		}
	}
}

// TestHookOmpUnknownActionIsTolerated ensures an unrecognised action is logged
// and swallowed rather than panicking or mutating state.
func TestHookOmpUnknownActionIsTolerated(t *testing.T) {
	r, _ := newTestRunner(t)
	stderr := runHookWithStdin(r, "omp", "no_such_action", "qm-omp", nil)
	if stderr == "" {
		t.Fatalf("expected a diagnostic for unknown omp action")
	}
}
