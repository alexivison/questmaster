package cmd

import (
	"bytes"
	"encoding/json"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/anthropics/ai-party/tools/party-cli/internal/state"
)

func newTestRunner(t *testing.T) (*HookRunner, *recordedHookCalls) {
	t.Helper()
	rec := &recordedHookCalls{}
	r := &HookRunner{
		Now: func() time.Time {
			// Fixed timestamp keeps assertions deterministic; the
			// production Now is time.Now.
			return time.Date(2026, 5, 20, 12, 0, 0, 0, time.UTC)
		},
		LoadTranscriptTail: func(path string) ([]byte, error) {
			rec.transcriptPaths = append(rec.transcriptPaths, path)
			return rec.transcriptTail, nil
		},
		Update: func(sessionID string, mutate func(*state.SessionState) bool) error {
			rec.updateCalls++
			ss := rec.lastState
			if ss == nil {
				ss = &state.SessionState{SessionID: sessionID, Version: state.SchemaVersion, Panes: map[string]state.PaneState{}}
			}
			if mutate(ss) {
				rec.lastState = ss
				rec.writeCalls++
			}
			return nil
		},
		AppendEvent: func(sessionID string, ev state.StateEvent) error {
			rec.events = append(rec.events, ev)
			return nil
		},
	}
	return r, rec
}

type recordedHookCalls struct {
	events          []state.StateEvent
	updateCalls     int
	writeCalls      int
	lastState       *state.SessionState
	transcriptPaths []string
	transcriptTail  []byte
}

func runHookWithStdin(r *HookRunner, agent, action, session string, payload interface{}) (stderr string) {
	var data []byte
	if payload != nil {
		data, _ = json.Marshal(payload)
	}
	var buf bytes.Buffer
	opts := hookOptions{agent: agent, action: action, session: session, stdin: data}
	runHook(r, opts, &buf)
	return buf.String()
}

func TestHookNoSessionExitsCleanly(t *testing.T) {
	t.Setenv("PARTY_SESSION", "")
	r, rec := newTestRunner(t)
	stderr := runHookWithStdin(r, "claude", "starting", "", nil)
	if stderr != "" {
		t.Errorf("unexpected stderr: %q", stderr)
	}
	if rec.updateCalls != 0 || len(rec.events) != 0 {
		t.Errorf("no-session call should be a no-op, got updates=%d events=%d", rec.updateCalls, len(rec.events))
	}
}

func TestHookInvalidSessionIsRejected(t *testing.T) {
	t.Setenv("PARTY_SESSION", "")
	r, rec := newTestRunner(t)
	stderr := runHookWithStdin(r, "claude", "starting", "../escape", nil)
	if !strings.Contains(stderr, "invalid PARTY_SESSION") {
		t.Errorf("expected invalid-session warning, got %q", stderr)
	}
	if rec.updateCalls != 0 {
		t.Errorf("invalid session must not touch state, got %d updates", rec.updateCalls)
	}
}

func TestHookClaudeStartingSetsState(t *testing.T) {
	r, rec := newTestRunner(t)
	stderr := runHookWithStdin(r, "claude", "starting", "party-abc", nil)
	if stderr != "" {
		t.Errorf("stderr: %q", stderr)
	}
	if rec.updateCalls != 1 || rec.writeCalls != 1 {
		t.Errorf("want one update+write, got %d/%d", rec.updateCalls, rec.writeCalls)
	}
	pane := rec.lastState.Panes["primary"]
	if pane.State != "starting" || pane.Activity != "starting…" || pane.LastKind != "SessionStart" {
		t.Errorf("starting pane: %+v", pane)
	}
}

func TestHookClaudeUserPromptSubmit(t *testing.T) {
	r, rec := newTestRunner(t)
	runHookWithStdin(r, "claude", "working", "party-abc", map[string]interface{}{
		"prompt": "What's the time?\nSecond line ignored",
	})
	pane := rec.lastState.Panes["primary"]
	if pane.State != "working" {
		t.Errorf("want state=working, got %q", pane.State)
	}
	if pane.Activity != "You: What's the time?" {
		t.Errorf("activity: %q", pane.Activity)
	}
	if pane.LastKind != "UserPromptSubmit" {
		t.Errorf("last_kind: %q", pane.LastKind)
	}
}

func TestHookClaudePreToolUseEdit(t *testing.T) {
	r, rec := newTestRunner(t)
	runHookWithStdin(r, "claude", "tool_start", "party-abc", map[string]interface{}{
		"tool_name":  "Edit",
		"tool_input": map[string]interface{}{"file_path": "/long/path/to/foo.go"},
	})
	pane := rec.lastState.Panes["primary"]
	if pane.State != "working" {
		t.Errorf("state: %q", pane.State)
	}
	if pane.Activity != "Edit foo.go" {
		t.Errorf("activity: %q", pane.Activity)
	}
	if pane.Tool != "Edit" {
		t.Errorf("tool: %q", pane.Tool)
	}
	if pane.LastKind != "PreToolUse" {
		t.Errorf("last_kind: %q", pane.LastKind)
	}
}

func TestHookClaudePreToolUseBashStripsEnvAssignments(t *testing.T) {
	r, rec := newTestRunner(t)
	runHookWithStdin(r, "claude", "tool_start", "party-abc", map[string]interface{}{
		"tool_name":  "Bash",
		"tool_input": map[string]interface{}{"command": "OPENAI_API_KEY=sk-xxx do-thing arg1 arg2"},
	})
	pane := rec.lastState.Panes["primary"]
	if strings.Contains(pane.Activity, "sk-xxx") {
		t.Errorf("leaked env value into Activity: %q", pane.Activity)
	}
	if !strings.HasPrefix(pane.Activity, "Bash: do-thing") {
		t.Errorf("unexpected activity: %q", pane.Activity)
	}
}

func TestHookClaudePostToolUseDoesNotClobberActivity(t *testing.T) {
	r, rec := newTestRunner(t)
	// Seed an in-flight Edit then post.
	rec.lastState = &state.SessionState{
		SessionID: "party-abc",
		Version:   state.SchemaVersion,
		Panes: map[string]state.PaneState{
			"primary": {Role: "primary", Agent: "claude", State: "working", Activity: "Edit foo.go", Tool: "Edit", LastKind: "PreToolUse"},
		},
	}
	runHookWithStdin(r, "claude", "tool_end", "party-abc", map[string]interface{}{"tool_name": "Edit"})
	pane := rec.lastState.Panes["primary"]
	if pane.Activity != "Edit foo.go" {
		t.Errorf("PostToolUse clobbered activity: %q", pane.Activity)
	}
	if pane.Tool != "" {
		t.Errorf("PostToolUse did not clear Tool: %q", pane.Tool)
	}
	if pane.LastKind != "PostToolUse" {
		t.Errorf("PostToolUse did not update LastKind: %q", pane.LastKind)
	}
}

func TestHookClaudeStopReadsTranscriptTail(t *testing.T) {
	r, rec := newTestRunner(t)
	rec.transcriptTail = []byte(`{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"All done — let me know."}]}}` + "\n")
	runHookWithStdin(r, "claude", "done", "party-abc", map[string]interface{}{
		"transcript_path": "/tmp/whatever.jsonl",
	})
	pane := rec.lastState.Panes["primary"]
	if pane.State != "done" {
		t.Errorf("state: %q", pane.State)
	}
	if !strings.HasPrefix(pane.Activity, "Said: All done") {
		t.Errorf("activity: %q", pane.Activity)
	}
	if len(rec.transcriptPaths) == 0 {
		t.Error("transcript_path was not consulted")
	}
}

func TestHookClaudeStopWithMissingTranscriptStillSucceeds(t *testing.T) {
	r, rec := newTestRunner(t)
	// LoadTranscriptTail in newTestRunner returns rec.transcriptTail (nil by default).
	runHookWithStdin(r, "claude", "done", "party-abc", map[string]interface{}{"transcript_path": "/nope.jsonl"})
	pane := rec.lastState.Panes["primary"]
	if pane.State != "done" {
		t.Errorf("state: %q", pane.State)
	}
	if pane.Activity != "" {
		t.Errorf("activity should be empty when transcript missing: %q", pane.Activity)
	}
}

func TestHookClaudeSubagentSuppressesParentState(t *testing.T) {
	r, rec := newTestRunner(t)
	rec.lastState = &state.SessionState{
		SessionID: "party-abc",
		Version:   state.SchemaVersion,
		Panes: map[string]state.PaneState{
			"primary": {Role: "primary", Agent: "claude", State: "working", Activity: "Edit foo.go", LastKind: "PreToolUse"},
		},
	}
	// Subagent Stop must not flip parent to done.
	runHookWithStdin(r, "claude", "done", "party-abc", map[string]interface{}{
		"agent_id":        "task-42",
		"transcript_path": "/tmp/whatever.jsonl",
	})
	pane := rec.lastState.Panes["primary"]
	if pane.State != "working" {
		t.Errorf("subagent should not flip parent State: got %q", pane.State)
	}
	if pane.Activity != "Edit foo.go" {
		t.Errorf("subagent done should not clobber parent Activity: got %q", pane.Activity)
	}
}

func TestHookClaudeSubagentToolEventDoesNotFlipParentState(t *testing.T) {
	r, rec := newTestRunner(t)
	rec.lastState = &state.SessionState{
		SessionID: "party-abc",
		Version:   state.SchemaVersion,
		Panes: map[string]state.PaneState{
			"primary": {Role: "primary", Agent: "claude", State: "idle", Activity: "old", LastKind: "Stop"},
		},
	}
	runHookWithStdin(r, "claude", "tool_start", "party-abc", map[string]interface{}{
		"agent_id":   "task-99",
		"tool_name":  "Read",
		"tool_input": map[string]interface{}{"file_path": "/x/y.go"},
	})
	pane := rec.lastState.Panes["primary"]
	if pane.State == "working" {
		t.Errorf("subagent tool_start should not flip parent State to working")
	}
	// Activity / Tool / LastKind still update so renderer can show what's happening.
	if pane.Activity != "Read y.go" {
		t.Errorf("subagent activity not recorded: %q", pane.Activity)
	}
}

func TestHookClaudeSubagentStopUpdatesActivityOnly(t *testing.T) {
	r, rec := newTestRunner(t)
	rec.lastState = &state.SessionState{
		SessionID: "party-abc",
		Version:   state.SchemaVersion,
		Panes: map[string]state.PaneState{
			"primary": {Role: "primary", Agent: "claude", State: "working", Activity: "Edit foo.go", LastKind: "PreToolUse"},
		},
	}
	runHookWithStdin(r, "claude", "subagent_stop", "party-abc", map[string]interface{}{
		"agent_id": "task-42",
		"result":   "Reviewed 12 files.\nDetails follow…",
	})
	pane := rec.lastState.Panes["primary"]
	if pane.State != "working" {
		t.Errorf("subagent_stop should never change State, got %q", pane.State)
	}
	if pane.Activity != "Subagent: Reviewed 12 files." {
		t.Errorf("subagent_stop activity: %q", pane.Activity)
	}
	if pane.LastKind != "SubagentStop" {
		t.Errorf("subagent_stop LastKind: %q", pane.LastKind)
	}
}

func TestHookClaudeBlocked(t *testing.T) {
	r, rec := newTestRunner(t)
	runHookWithStdin(r, "claude", "blocked", "party-abc", map[string]interface{}{
		"message": "Permission needed: edit /etc/hosts",
	})
	pane := rec.lastState.Panes["primary"]
	if pane.State != "blocked" {
		t.Errorf("state: %q", pane.State)
	}
	if !strings.HasPrefix(pane.Activity, "Notification: Permission needed") {
		t.Errorf("activity: %q", pane.Activity)
	}
}

func TestHookClaudeUnknownActionWarnsButDoesNotPanic(t *testing.T) {
	r, rec := newTestRunner(t)
	stderr := runHookWithStdin(r, "claude", "no-such-action", "party-abc", nil)
	if !strings.Contains(stderr, "unknown action") {
		t.Errorf("want unknown-action warning, got %q", stderr)
	}
	if rec.updateCalls != 0 {
		t.Error("unknown action should not write state")
	}
}

func TestHookClaudeTolerantPayload(t *testing.T) {
	r, _ := newTestRunner(t)
	// Garbage stdin: a non-JSON byte stream. The hook must still record
	// the event without panicking.
	opts := hookOptions{agent: "claude", action: "tool_start", session: "party-abc", stdin: []byte("not json at all")}
	var buf bytes.Buffer
	runHook(r, opts, &buf)
	// Either silently tolerated or warning emitted — both acceptable.
	// What's NOT acceptable is a panic, which would fail the test
	// outright via recover-less crash.
}

func TestHookCodexEndToEnd(t *testing.T) {
	r, rec := newTestRunner(t)
	for _, step := range []struct {
		name         string
		action       string
		payload      map[string]interface{}
		wantState    string
		wantActivity string
		wantTool     string
		wantKind     string
	}{
		{
			name:         "session start",
			action:       "starting",
			payload:      map[string]interface{}{"hook_event_name": "SessionStart"},
			wantState:    "starting",
			wantActivity: "starting…",
			wantKind:     "SessionStart",
		},
		{
			name:         "user prompt",
			action:       "working",
			payload:      map[string]interface{}{"hook_event_name": "UserPromptSubmit", "prompt": "What changed?\nignore"},
			wantState:    "working",
			wantActivity: "You: What changed?",
			wantKind:     "UserPromptSubmit",
		},
		{
			name:         "pre tool",
			action:       "tool_start",
			payload:      map[string]interface{}{"hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": map[string]interface{}{"command": "OPENAI_API_KEY=sk-test echo hi"}},
			wantState:    "working",
			wantActivity: "Bash: echo hi",
			wantTool:     "Bash",
			wantKind:     "PreToolUse",
		},
		{
			name:         "post tool",
			action:       "tool_end",
			payload:      map[string]interface{}{"hook_event_name": "PostToolUse", "tool_name": "Bash"},
			wantState:    "working",
			wantActivity: "Bash: echo hi",
			wantKind:     "PostToolUse",
		},
		{
			name:         "stop",
			action:       "done",
			payload:      map[string]interface{}{"hook_event_name": "Stop", "agent_id": "ignored-by-codex", "last_assistant_message": "All set.\nignore"},
			wantState:    "done",
			wantActivity: "Said: All set.",
			wantKind:     "Stop",
		},
	} {
		stderr := runHookWithStdin(r, "codex", step.action, "party-abc", step.payload)
		if stderr != "" {
			t.Fatalf("%s stderr: %q", step.name, stderr)
		}
		pane := rec.lastState.Panes["primary"]
		if pane.State != step.wantState {
			t.Errorf("%s state: want %q got %q", step.name, step.wantState, pane.State)
		}
		if pane.Activity != step.wantActivity {
			t.Errorf("%s activity: want %q got %q", step.name, step.wantActivity, pane.Activity)
		}
		if pane.Tool != step.wantTool {
			t.Errorf("%s tool: want %q got %q", step.name, step.wantTool, pane.Tool)
		}
		if pane.LastKind != step.wantKind {
			t.Errorf("%s last_kind: want %q got %q", step.name, step.wantKind, pane.LastKind)
		}
	}
	if len(rec.events) != 5 {
		t.Fatalf("events: want 5 got %d", len(rec.events))
	}
	for _, ev := range rec.events {
		if ev.Agent != "codex" {
			t.Errorf("event agent: %+v", ev)
		}
	}
}

func TestHookPiEventsEndToEnd(t *testing.T) {
	r, rec := newTestRunner(t)
	longCommand := "OPENAI_API_KEY=sk-xxx echo hello from pi with a command that is deliberately long enough to truncate"
	steps := []struct {
		action       string
		payload      map[string]interface{}
		wantState    string
		wantActivity string
		wantTool     string
	}{
		{
			action: "session_start",
			payload: map[string]interface{}{
				"session_file":  "2026-05-20T12-00-00-000Z_123e4567-e89b-12d3-a456-426614174000.jsonl",
				"pi_session_id": "123e4567-e89b-12d3-a456-426614174000",
				"recent":        []string{"previous line"},
			},
			wantState:    "starting",
			wantActivity: "starting…",
		},
		{action: "before_agent_start", wantState: "starting", wantActivity: "starting…"},
		{action: "agent_start", wantState: "starting", wantActivity: "starting…"},
		{action: "message_update", wantState: "working", wantActivity: "Replying…"},
		{
			action: "message_end",
			payload: map[string]interface{}{
				"message": map[string]interface{}{
					"role":    "assistant",
					"content": []interface{}{map[string]interface{}{"type": "text", "text": "Hello\nfrom Pi"}},
				},
			},
			wantState:    "working",
			wantActivity: "Replying…",
		},
		{
			action: "tool_execution_start",
			payload: map[string]interface{}{
				"toolName": "bash",
				"args":     map[string]interface{}{"command": longCommand},
			},
			wantState:    "working",
			wantActivity: "bash: echo hello from pi with a command that is deliberately",
			wantTool:     "bash",
		},
		{action: "tool_execution_end", payload: map[string]interface{}{"toolName": "bash"}, wantState: "working", wantActivity: "bash: echo hello from pi with a command that is deliberately"},
		{
			action: "agent_end",
			payload: map[string]interface{}{
				"messages": []interface{}{
					map[string]interface{}{"role": "user", "content": "ignored"},
					map[string]interface{}{"role": "assistant", "content": []interface{}{map[string]interface{}{"type": "text", "text": "Final answer\nsecond line ignored"}}},
				},
			},
			wantState:    "done",
			wantActivity: "Said: Final answer",
		},
		{action: "session_shutdown", wantState: "stopped", wantActivity: "Said: Final answer"},
	}

	for _, step := range steps {
		stderr := runHookWithStdin(r, "pi", step.action, "party-abc", step.payload)
		if stderr != "" {
			t.Fatalf("%s stderr: %q", step.action, stderr)
		}
		pane := rec.lastState.Panes["primary"]
		if pane.State != step.wantState {
			t.Fatalf("%s state: want %q, got %+v", step.action, step.wantState, pane)
		}
		if pane.Activity != step.wantActivity {
			t.Fatalf("%s activity: want %q, got %q", step.action, step.wantActivity, pane.Activity)
		}
		if pane.Tool != step.wantTool {
			t.Fatalf("%s tool: want %q, got %q", step.action, step.wantTool, pane.Tool)
		}
		if pane.Agent != "pi" || pane.Role != "primary" {
			t.Fatalf("%s pane identity: %+v", step.action, pane)
		}
		if pane.LastKind != step.action {
			t.Fatalf("%s last_kind: %q", step.action, pane.LastKind)
		}
	}

	pane := rec.lastState.Panes["primary"]
	if pane.SessionFile != "2026-05-20T12-00-00-000Z_123e4567-e89b-12d3-a456-426614174000.jsonl" {
		t.Errorf("session_file not carried through: %q", pane.SessionFile)
	}
	if pane.PiSessionID != "123e4567-e89b-12d3-a456-426614174000" {
		t.Errorf("pi_session_id not carried through: %q", pane.PiSessionID)
	}
	if len(pane.Recent) == 0 || pane.Recent[len(pane.Recent)-1] != "second line ignored" {
		t.Errorf("recent not carried through/derived: %+v", pane.Recent)
	}
	if len(rec.events) != len(steps) {
		t.Errorf("event count: want %d, got %d", len(steps), len(rec.events))
	}
	if rec.updateCalls != len(steps) || rec.writeCalls != len(steps) {
		t.Errorf("updates/writes: want %d/%d, got %d/%d", len(steps), len(steps), rec.updateCalls, rec.writeCalls)
	}
}

// TestHookDoesNotCallDiscoverSessions enforces the invariant in PLAN.md
// line 492: the hot path must never enumerate sessions. We parse the
// hook source and walk the AST for any reference to "DiscoverSessions".
func TestHookDoesNotCallDiscoverSessions(t *testing.T) {
	src, err := os.ReadFile("hook.go")
	if err != nil {
		t.Fatalf("read hook.go: %v", err)
	}
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, "hook.go", src, 0)
	if err != nil {
		t.Fatalf("parse hook.go: %v", err)
	}
	ast.Inspect(f, func(n ast.Node) bool {
		switch node := n.(type) {
		case *ast.SelectorExpr:
			if node.Sel != nil && node.Sel.Name == "DiscoverSessions" {
				t.Errorf("hook.go references DiscoverSessions at %s", fset.Position(node.Pos()))
			}
		case *ast.Ident:
			if node.Name == "DiscoverSessions" {
				t.Errorf("hook.go references DiscoverSessions at %s", fset.Position(node.Pos()))
			}
		}
		return true
	})
}

// TestRoundTripState writes via UpdateSessionState then loads via
// LoadSessionState. This double-checks the runHook path against the real
// disk-backed store (no fake HookRunner).
func TestHookEndToEndOnDisk(t *testing.T) {
	root := t.TempDir()
	t.Setenv("PARTY_STATE_ROOT", root)

	r := defaultHookRunner()
	r.Now = func() time.Time { return time.Date(2026, 5, 20, 12, 0, 0, 0, time.UTC) }
	r.LoadTranscriptTail = func(string) ([]byte, error) { return nil, nil }

	for _, step := range []struct {
		action  string
		payload map[string]interface{}
	}{
		{"starting", nil},
		{"working", map[string]interface{}{"prompt": "hi there"}},
		{"tool_start", map[string]interface{}{"tool_name": "Edit", "tool_input": map[string]interface{}{"file_path": "/x/y.go"}}},
		{"tool_end", map[string]interface{}{"tool_name": "Edit"}},
		{"done", nil},
	} {
		var data []byte
		if step.payload != nil {
			data, _ = json.Marshal(step.payload)
		}
		var buf bytes.Buffer
		runHook(r, hookOptions{agent: "claude", action: step.action, session: "party-disk", stdin: data}, &buf)
		if s := buf.String(); s != "" {
			t.Errorf("step %s stderr: %q", step.action, s)
		}
	}

	ss, err := state.LoadSessionState("party-disk")
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if ss.Panes["primary"].State != "done" {
		t.Errorf("final state: %+v", ss.Panes["primary"])
	}
	if _, err := os.Stat(filepath.Join(root, "party-disk", "state.jsonl")); err != nil {
		t.Errorf("state.jsonl missing: %v", err)
	}
}
