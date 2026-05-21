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

// TestHookStartingSnippetIsStarted pins the starting-state Activity snippet
// to "started" (not "starting…") for every agent. The tracker renders the
// state as "idle (started)" with the idle glyph, so the snippet has to
// match — anything else (the old ellipsis variant included) would either
// look like a stale pre-PR string or fight the new render.
func TestHookStartingSnippetIsStarted(t *testing.T) {
	cases := []struct {
		agent  string
		action string
	}{
		{agent: "claude", action: "starting"},
		{agent: "codex", action: "starting"},
		{agent: "pi", action: "session_start"},
		{agent: "pi", action: "before_agent_start"},
		{agent: "pi", action: "agent_start"},
	}
	for _, tc := range cases {
		t.Run(tc.agent+"/"+tc.action, func(t *testing.T) {
			r, rec := newTestRunner(t)
			stderr := runHookWithStdin(r, tc.agent, tc.action, "party-abc", nil)
			if stderr != "" {
				t.Fatalf("stderr: %q", stderr)
			}
			pane := rec.lastState.Panes["primary"]
			if pane.State != "starting" {
				t.Fatalf("state = %q, want starting", pane.State)
			}
			if pane.Activity != "started" {
				t.Fatalf("activity = %q, want %q", pane.Activity, "started")
			}
		})
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
	if pane.State != "starting" || pane.Activity != "started" || pane.LastKind != "SessionStart" {
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
	if pane.Activity != "Edit: foo.go" {
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
			"primary": {Role: "primary", Agent: "claude", State: "working", Activity: "Edit: foo.go", Tool: "Edit", LastKind: "PreToolUse"},
		},
	}
	runHookWithStdin(r, "claude", "tool_end", "party-abc", map[string]interface{}{"tool_name": "Edit"})
	pane := rec.lastState.Panes["primary"]
	if pane.Activity != "Edit: foo.go" {
		t.Errorf("PostToolUse clobbered activity: %q", pane.Activity)
	}
	if pane.Tool != "" {
		t.Errorf("PostToolUse did not clear Tool: %q", pane.Tool)
	}
	if pane.LastKind != "PostToolUse" {
		t.Errorf("PostToolUse did not update LastKind: %q", pane.LastKind)
	}
}

// TestHookClaudePostToolUseClearsStaleNotificationActivity simulates the
// production sequence: PreToolUse (working/"Edit: foo.go") → Notification
// (blocked/"Notification: …") → user grants permission → PostToolUse.
// The PreToolUse snippet is already lost (Notification overwrote it),
// so the pane must NOT keep showing "Notification: …" — clear it
// instead so the next PreToolUse / UserPromptSubmit can refill it.
func TestHookClaudePostToolUseClearsStaleNotificationActivity(t *testing.T) {
	r, rec := newTestRunner(t)
	runHookWithStdin(r, "claude", "tool_start", "party-abc", map[string]interface{}{
		"tool_name":  "Edit",
		"tool_input": map[string]interface{}{"file_path": "/repo/foo.go"},
	})
	runHookWithStdin(r, "claude", "blocked", "party-abc", map[string]interface{}{
		"message": "Permission needed: edit /repo/foo.go",
	})
	pane := rec.lastState.Panes["primary"]
	if !strings.HasPrefix(pane.Activity, "Notification: ") {
		t.Fatalf("precondition: Notification did not overwrite Activity, got %q", pane.Activity)
	}
	runHookWithStdin(r, "claude", "tool_end", "party-abc", map[string]interface{}{"tool_name": "Edit"})
	pane = rec.lastState.Panes["primary"]
	if pane.Activity != "" {
		t.Errorf("PostToolUse left stale Notification snippet: %q", pane.Activity)
	}
	if pane.State != "working" {
		t.Errorf("PostToolUse should flip State back to working, got %q", pane.State)
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
	if !strings.HasPrefix(pane.Activity, "All done") {
		t.Errorf("activity: %q", pane.Activity)
	}
	if len(rec.transcriptPaths) == 0 {
		t.Error("transcript_path was not consulted")
	}
}

// TestHookClaudeStopPrefersLastAssistantMessage covers the regression
// where Claude's Stop fires before the transcript flush completes and
// saidSnippet returns "". The hook must read the payload's
// last_assistant_message field (mirrors the Codex pattern) and skip
// the transcript tail entirely when the payload field is populated.
func TestHookClaudeStopPrefersLastAssistantMessage(t *testing.T) {
	r, rec := newTestRunner(t)
	// Set a transcript tail that would otherwise win — this assertion
	// proves the payload field takes precedence.
	rec.transcriptTail = []byte(`{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"transcript snippet"}]}}` + "\n")
	runHookWithStdin(r, "claude", "done", "party-abc", map[string]interface{}{
		"transcript_path":        "/tmp/whatever.jsonl",
		"last_assistant_message": "Why do Finns make great secret agents?",
	})
	pane := rec.lastState.Panes["primary"]
	if pane.State != "done" {
		t.Errorf("state: %q", pane.State)
	}
	if pane.Activity != "Why do Finns make great secret agents?" {
		t.Errorf("activity: %q, want 'Why do Finns make great secret agents?'", pane.Activity)
	}
}

// TestHookClaudeStopFallsBackToTranscriptTail asserts the transcript
// fallback still runs when the payload omits last_assistant_message.
func TestHookClaudeStopFallsBackToTranscriptTail(t *testing.T) {
	r, rec := newTestRunner(t)
	rec.transcriptTail = []byte(`{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"from transcript"}]}}` + "\n")
	runHookWithStdin(r, "claude", "done", "party-abc", map[string]interface{}{
		"transcript_path": "/tmp/whatever.jsonl",
	})
	pane := rec.lastState.Panes["primary"]
	if pane.Activity != "from transcript" {
		t.Errorf("activity: %q, want 'from transcript'", pane.Activity)
	}
	if len(rec.transcriptPaths) == 0 {
		t.Error("transcript_path was not consulted in fallback path")
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
			"primary": {Role: "primary", Agent: "claude", State: "working", Activity: "Edit: foo.go", LastKind: "PreToolUse"},
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
	if pane.Activity != "Edit: foo.go" {
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
	if pane.Activity != "Read: y.go" {
		t.Errorf("subagent activity not recorded: %q", pane.Activity)
	}
}

func TestHookClaudeSubagentStopUpdatesActivityOnly(t *testing.T) {
	r, rec := newTestRunner(t)
	rec.lastState = &state.SessionState{
		SessionID: "party-abc",
		Version:   state.SchemaVersion,
		Panes: map[string]state.PaneState{
			"primary": {Role: "primary", Agent: "claude", State: "working", Activity: "Edit: foo.go", LastKind: "PreToolUse"},
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

func TestHookClaudeAskUserQuestionShowsQuestionSnippet(t *testing.T) {
	r, rec := newTestRunner(t)
	runHookWithStdin(r, "claude", "tool_start", "party-abc", map[string]interface{}{
		"tool_name": "AskUserQuestion",
		"tool_input": map[string]interface{}{
			"questions": []interface{}{
				map[string]interface{}{
					"question": "What is your favorite color?",
					"header":   "Color",
				},
			},
		},
	})
	pane := rec.lastState.Panes["primary"]
	if pane.State != "blocked" {
		t.Errorf("state: %q, want blocked", pane.State)
	}
	if pane.Activity != "Question: What is your favorite color?" {
		t.Errorf("activity: %q", pane.Activity)
	}
	if pane.Tool != "AskUserQuestion" {
		t.Errorf("tool: %q", pane.Tool)
	}
}

func TestHookClaudeAskUserQuestionNotificationPreservesQuestionActivity(t *testing.T) {
	r, rec := newTestRunner(t)
	rec.lastState = &state.SessionState{
		SessionID: "party-abc",
		Version:   state.SchemaVersion,
		Panes: map[string]state.PaneState{
			"primary": {Role: "primary", Agent: "claude", State: "blocked", Activity: "Question: What is your favorite color?", Tool: "AskUserQuestion", LastKind: "PreToolUse"},
		},
	}
	runHookWithStdin(r, "claude", "blocked", "party-abc", map[string]interface{}{
		"message": "Claude needs your permission",
	})
	pane := rec.lastState.Panes["primary"]
	if pane.Activity != "Question: What is your favorite color?" {
		t.Errorf("Notification clobbered Question activity: %q", pane.Activity)
	}
	if pane.State != "blocked" {
		t.Errorf("state: %q, want blocked", pane.State)
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

// TestStopReadsAssistantBeyond4KB enforces that the Stop tail is large
// enough to find an assistant message that sits past the original 4 KiB
// limit. Real Claude transcripts append many post-message metadata
// records, so the assistant message can land tens of KiB before EOF.
func TestStopReadsAssistantBeyond4KB(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "transcript.jsonl")
	f, err := os.Create(path)
	if err != nil {
		t.Fatalf("create transcript: %v", err)
	}
	// Assistant message first, then ~30 KiB of trailing metadata
	// records — total payload sits between the old 4 KiB tail and the
	// new 64 KiB tail.
	assistantLine := `{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"All done — let me know."}]}}` + "\n"
	if _, err := f.WriteString(assistantLine); err != nil {
		t.Fatalf("write assistant: %v", err)
	}
	metaLine := `{"type":"system","kind":"attachment","payload":"` + strings.Repeat("x", 300) + `"}` + "\n"
	for i := 0; i < 100; i++ { // ~30 KiB of trailing metadata
		if _, err := f.WriteString(metaLine); err != nil {
			t.Fatalf("write meta: %v", err)
		}
	}
	if err := f.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	r := defaultHookRunner()
	r.Now = func() time.Time { return time.Date(2026, 5, 20, 12, 0, 0, 0, time.UTC) }
	root := t.TempDir()
	t.Setenv("PARTY_STATE_ROOT", root)

	payload, _ := json.Marshal(map[string]interface{}{"transcript_path": path})
	var buf bytes.Buffer
	runHook(r, hookOptions{agent: "claude", action: "done", session: "party-tail", stdin: payload}, &buf)
	if s := buf.String(); s != "" {
		t.Errorf("stderr: %q", s)
	}

	ss, err := state.LoadSessionState("party-tail")
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	pane := ss.Panes["primary"]
	if pane.State != "done" {
		t.Errorf("state: %q", pane.State)
	}
	if !strings.HasPrefix(pane.Activity, "All done") {
		t.Errorf("activity: %q (assistant message not extracted from 64 KiB tail)", pane.Activity)
	}
}

// TestNotificationIdleDoesNotFlipState reproduces the false-positive
// flow from production logs: Stop fires (state=done), then ~60s later
// Claude fires Notification with "Claude is waiting for your input" —
// the agent is idle, not blocked. State must stay done.
func TestNotificationIdleDoesNotFlipState(t *testing.T) {
	r, rec := newTestRunner(t)
	rec.lastState = &state.SessionState{
		SessionID: "party-abc",
		Version:   state.SchemaVersion,
		Panes: map[string]state.PaneState{
			"primary": {Role: "primary", Agent: "claude", State: "done", Activity: "All done.", LastKind: "Stop"},
		},
	}
	runHookWithStdin(r, "claude", "blocked", "party-abc", map[string]interface{}{
		"message": "Claude is waiting for your input",
	})
	pane := rec.lastState.Panes["primary"]
	if pane.State != "done" {
		t.Errorf("idle-waiting Notification should not flip State, got %q", pane.State)
	}
	if pane.Activity != "All done." {
		t.Errorf("idle-waiting Notification should not clobber Activity, got %q", pane.Activity)
	}
	if pane.LastKind != "Notification" {
		t.Errorf("LastKind should record the Notification arrived, got %q", pane.LastKind)
	}
}

// TestNotificationGenuineFlipsBlocked confirms permission/approval
// Notifications still produce state=blocked.
func TestNotificationGenuineFlipsBlocked(t *testing.T) {
	r, rec := newTestRunner(t)
	runHookWithStdin(r, "claude", "blocked", "party-abc", map[string]interface{}{
		"message": "Permission required for X",
	})
	pane := rec.lastState.Panes["primary"]
	if pane.State != "blocked" {
		t.Errorf("genuine Notification should flip blocked, got %q", pane.State)
	}
	if !strings.HasPrefix(pane.Activity, "Notification: Permission required") {
		t.Errorf("activity: %q", pane.Activity)
	}
	if pane.LastKind != "Notification" {
		t.Errorf("LastKind: %q", pane.LastKind)
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
			wantActivity: "started",
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
			wantActivity: "All set.",
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

func TestHookCodexPermissionRequestBlocked(t *testing.T) {
	tests := []struct {
		name    string
		payload map[string]interface{}
		want    string
	}{
		{
			name: "message",
			payload: map[string]interface{}{
				"message":    "Allow Codex to run this command?\nsecond line",
				"permission": "ignored because message wins",
			},
			want: "Permission: Allow Codex to run this command?",
		},
		{
			name: "tool input command",
			payload: map[string]interface{}{
				"tool_input": map[string]interface{}{"command": "OPENAI_API_KEY=sk-test git status --short"},
			},
			want: "Permission: git status --short",
		},
		{
			name:    "permission fallback",
			payload: map[string]interface{}{"permission": "approval required"},
			want:    "Permission: approval required",
		},
		{
			name:    "generic fallback",
			payload: map[string]interface{}{},
			want:    "Permission: Permission required",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r, rec := newTestRunner(t)
			stderr := runHookWithStdin(r, "codex", "permission", "party-abc", tt.payload)
			if stderr != "" {
				t.Fatalf("stderr: %q", stderr)
			}
			pane := rec.lastState.Panes["primary"]
			if pane.State != "blocked" {
				t.Errorf("state: %q", pane.State)
			}
			if pane.Activity != tt.want {
				t.Errorf("activity: want %q got %q", tt.want, pane.Activity)
			}
			if !strings.HasPrefix(pane.Activity, "Permission: ") {
				t.Errorf("activity should start with Permission: got %q", pane.Activity)
			}
			if pane.LastKind != "PermissionRequest" {
				t.Errorf("last_kind: %q", pane.LastKind)
			}
		})
	}
}

func TestPiPromptActivityUsesUserPrefix(t *testing.T) {
	if got := piPromptActivity(piPayload{Prompt: "Fix this\nignore"}); got != "You: Fix this" {
		t.Fatalf("prompt activity: want %q, got %q", "You: Fix this", got)
	}
	if got := piPromptActivity(piPayload{Text: "Fallback text"}); got != "You: Fallback text" {
		t.Fatalf("text activity: want %q, got %q", "You: Fallback text", got)
	}
	if got := piPromptActivity(piPayload{}); got != "" {
		t.Fatalf("empty prompt activity: want empty, got %q", got)
	}
}

func TestPiToolActivityUsesClaudeVocabulary(t *testing.T) {
	tests := []struct {
		name    string
		payload piPayload
		want    string
	}{
		{
			name:    "edit",
			payload: piPayload{ToolName: "write", Args: map[string]interface{}{"path": "/tmp/foo.go"}},
			want:    "Edit: foo.go",
		},
		{
			name:    "apply patch",
			payload: piPayload{ToolName: "apply_patch", Args: map[string]interface{}{"file_path": "/tmp/patch.go"}},
			want:    "Edit: patch.go",
		},
		{
			name:    "read from summary",
			payload: piPayload{Tool: piToolPayload{Name: "read", Summary: "read: /tmp/bar.md"}},
			want:    "Read: bar.md",
		},
		{
			name:    "bash",
			payload: piPayload{Name: "shell", Arguments: map[string]interface{}{"cmd": "OPENAI_API_KEY=sk-test echo hi"}},
			want:    "Bash: echo hi",
		},
		{
			name:    "agent",
			payload: piPayload{ToolNameSnake: "Task", Input: map[string]interface{}{"description": "check this\nignore"}},
			want:    "Agent: check this",
		},
		{
			name:    "search",
			payload: piPayload{Tool: piToolPayload{ToolName: "grep"}, Args: map[string]interface{}{"pattern": "needle\nignore"}},
			want:    "Search: needle",
		},
		{
			name:    "unknown raw name",
			payload: piPayload{Name: "custom_tool", Args: map[string]interface{}{"query": "ignored"}},
			want:    "custom_tool",
		},
		{
			name:    "summary fallback",
			payload: piPayload{Tool: piToolPayload{Summary: "tool summary"}},
			want:    "tool summary",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := piToolActivity(tt.payload); got != tt.want {
				t.Fatalf("piToolActivity() = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestHookPiMessageActivityUsesStreamingText(t *testing.T) {
	tests := []struct {
		action  string
		payload map[string]interface{}
		want    string
	}{
		{
			action:  "message_update",
			payload: map[string]interface{}{"snippet": "Streaming answer\nignored"},
			want:    "Streaming answer",
		},
		{
			action: "message_end",
			payload: map[string]interface{}{
				"message": map[string]interface{}{
					"role":    "assistant",
					"content": []interface{}{map[string]interface{}{"type": "text", "text": "Finished answer\nignored"}},
				},
			},
			want: "Finished answer",
		},
	}

	for _, tt := range tests {
		t.Run(tt.action, func(t *testing.T) {
			r, rec := newTestRunner(t)
			runHookWithStdin(r, "pi", tt.action, "party-abc", tt.payload)
			pane := rec.lastState.Panes["primary"]
			if pane.Activity != tt.want {
				t.Fatalf("activity: want %q, got %q", tt.want, pane.Activity)
			}
		})
	}
}

func TestHookPiMessageActivityFallsBackWhenTextMissing(t *testing.T) {
	for _, action := range []string{"message_update", "message_end"} {
		t.Run(action, func(t *testing.T) {
			r, rec := newTestRunner(t)
			runHookWithStdin(r, "pi", action, "party-abc", nil)
			pane := rec.lastState.Panes["primary"]
			if pane.Activity != "Replying…" {
				t.Fatalf("activity: want %q, got %q", "Replying…", pane.Activity)
			}
		})
	}
}

func TestHookPiWaitingForUserBlocksWithQuestion(t *testing.T) {
	r, rec := newTestRunner(t)
	runHookWithStdin(r, "pi", "waiting_for_user", "party-abc", map[string]interface{}{
		"prompt": "Pick a deployment target\nignored",
		"tool":   map[string]interface{}{"name": "ask_user", "summary": "Fallback question"},
	})
	pane := rec.lastState.Panes["primary"]
	if pane.State != "blocked" {
		t.Fatalf("state: want %q, got %+v", "blocked", pane)
	}
	if !strings.HasPrefix(pane.Activity, "Question: ") {
		t.Fatalf("activity should start with Question: got %q", pane.Activity)
	}
	if pane.Activity != "Question: Pick a deployment target" {
		t.Fatalf("activity: want %q, got %q", "Question: Pick a deployment target", pane.Activity)
	}
	if pane.Tool != "ask_user" {
		t.Fatalf("tool: want %q, got %q", "ask_user", pane.Tool)
	}
	if pane.LastKind != "waiting_for_user" {
		t.Fatalf("last_kind: want %q, got %q", "waiting_for_user", pane.LastKind)
	}

	runHookWithStdin(r, "pi", "tool_execution_start", "party-abc", map[string]interface{}{"toolName": "ask_user"})
	pane = rec.lastState.Panes["primary"]
	if pane.State != "blocked" || pane.Activity != "Question: Pick a deployment target" || pane.LastKind != "waiting_for_user" {
		t.Fatalf("tool heartbeat should preserve blocked question, got %+v", pane)
	}

	runHookWithStdin(r, "pi", "tool_execution_end", "party-abc", map[string]interface{}{"toolName": "ask_user"})
	pane = rec.lastState.Panes["primary"]
	if pane.State != "working" || pane.Activity != "" || pane.Tool != "" || pane.LastKind != "tool_execution_end" {
		t.Fatalf("tool end should clear blocked question, got %+v", pane)
	}
}

func TestHookPiEventsEndToEnd(t *testing.T) {
	r, rec := newTestRunner(t)
	command := "OPENAI_API_KEY=sk-xxx echo hello from pi"
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
			wantActivity: "started",
		},
		{action: "before_agent_start", wantState: "starting", wantActivity: "started"},
		{action: "agent_start", wantState: "starting", wantActivity: "started"},
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
			wantActivity: "Hello",
		},
		{
			action: "tool_execution_start",
			payload: map[string]interface{}{
				"toolName": "bash",
				"args":     map[string]interface{}{"command": command},
			},
			wantState:    "working",
			wantActivity: "Bash: echo hello from pi",
			wantTool:     "bash",
		},
		{action: "tool_execution_end", payload: map[string]interface{}{"toolName": "bash"}, wantState: "working", wantActivity: "Bash: echo hello from pi"},
		{
			action: "agent_end",
			payload: map[string]interface{}{
				"messages": []interface{}{
					map[string]interface{}{"role": "user", "content": "ignored"},
					map[string]interface{}{"role": "assistant", "content": []interface{}{map[string]interface{}{"type": "text", "text": "Final answer\nsecond line ignored"}}},
				},
			},
			wantState:    "done",
			wantActivity: "Final answer",
		},
		{action: "session_shutdown", wantState: "stopped", wantActivity: "Final answer"},
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
