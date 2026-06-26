package cmd

import (
	"bufio"
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/state"
)

func TestHookOpenCodeSessionCreatedFixtureCapturesResumeID(t *testing.T) {
	sessionID := "qm-opencode-hook-fixture"
	runtimeDir := filepath.Join("/tmp", sessionID)
	_ = os.RemoveAll(runtimeDir)
	t.Cleanup(func() { _ = os.RemoveAll(runtimeDir) })

	r, rec := newTestRunner(t)
	store := newManifestStoreStub(sessionID, nil)
	store.manifest.Agents = []state.AgentManifest{{Name: "opencode", Role: "primary", CLI: "opencode", Window: 1}}
	tmuxStub := &tmuxEnvStub{}
	r.Store = store
	r.TmuxClient = tmuxStub

	raw := openCodeFixtureEvent(t, "session.created")
	stderr := runOpenCodeHookRaw(r, sessionID, raw)
	if stderr != "" {
		t.Fatalf("stderr: %q", stderr)
	}

	pane := rec.lastState.Panes["primary"]
	wantSessionID := "ses_0fe71403bffelkVzqKPjzrKxTZ"
	if pane.State != "starting" || pane.Activity != "Session created" || pane.OpenCodeSessionID != wantSessionID {
		t.Fatalf("pane after session.created: %+v", pane)
	}
	if got := store.manifest.ExtraString("opencode_session_id"); got != wantSessionID {
		t.Fatalf("manifest opencode_session_id = %q, want %q", got, wantSessionID)
	}
	if got := store.manifest.Agents[0].ResumeID; got != wantSessionID {
		t.Fatalf("agent resume id = %q, want %q", got, wantSessionID)
	}
	if len(tmuxStub.calls) != 1 || tmuxStub.calls[0].key != "OPENCODE_SESSION_ID" || tmuxStub.calls[0].value != wantSessionID {
		t.Fatalf("tmux env calls = %+v", tmuxStub.calls)
	}
	data, err := os.ReadFile(filepath.Join(runtimeDir, "opencode-session-id"))
	if err != nil {
		t.Fatalf("read runtime resume id: %v", err)
	}
	if got := strings.TrimSpace(string(data)); got != wantSessionID {
		t.Fatalf("runtime resume id = %q, want %q", got, wantSessionID)
	}
	if len(rec.events) != 1 || rec.events[0].Action != "session.created" {
		t.Fatalf("events = %+v", rec.events)
	}
}

func TestHookOpenCodeMapsStatusToolPermissionAndDone(t *testing.T) {
	r, rec := newTestRunner(t)
	sessionID := "qm-opencode-map"
	cleanupRuntimeDir(t, sessionID)
	openCodeHookEvent(t, r, sessionID, "session.status", map[string]interface{}{
		"sessionID": "ses_mapping",
		"status":    map[string]interface{}{"type": "busy"},
	})
	pane := rec.lastState.Panes["primary"]
	if pane.State != "working" {
		t.Fatalf("busy state = %q, want working", pane.State)
	}

	openCodeHookEvent(t, r, sessionID, "tool.execute.before", map[string]interface{}{
		"sessionID": "ses_mapping",
		"tool":      "bash",
	})
	pane = rec.lastState.Panes["primary"]
	if pane.State != "working" || pane.Tool != "bash" || pane.Activity != "Tool: bash" {
		t.Fatalf("tool before pane: %+v", pane)
	}

	openCodeHookEvent(t, r, sessionID, "permission.asked", map[string]interface{}{
		"sessionID":  "ses_mapping",
		"permission": map[string]interface{}{"id": "perm_bash", "tool": "bash"},
	})
	pane = rec.lastState.Panes["primary"]
	if pane.State != "blocked" || pane.Activity != "Permission: perm_bash" {
		t.Fatalf("permission pane: %+v", pane)
	}

	openCodeHookEvent(t, r, sessionID, "session.idle", map[string]interface{}{
		"sessionID": "ses_mapping",
	})
	pane = rec.lastState.Panes["primary"]
	if pane.State != "blocked" {
		t.Fatalf("idle must not clear permission block: %+v", pane)
	}

	openCodeHookEvent(t, r, sessionID, "permission.replied", map[string]interface{}{
		"sessionID":  "ses_mapping",
		"permission": map[string]interface{}{"id": "perm_bash", "action": "allow"},
	})
	pane = rec.lastState.Panes["primary"]
	if pane.State != "working" || pane.Activity != "Permission replied" {
		t.Fatalf("permission replied pane: %+v", pane)
	}

	openCodeHookEvent(t, r, sessionID, "tool.execute.after", map[string]interface{}{
		"sessionID": "ses_mapping",
		"tool":      "bash",
	})
	pane = rec.lastState.Panes["primary"]
	if pane.State != "working" || pane.Tool != "" || pane.Activity != "Tool done: bash" {
		t.Fatalf("tool after pane: %+v", pane)
	}

	openCodeHookEvent(t, r, sessionID, "message.part.updated", map[string]interface{}{
		"sessionID": "ses_mapping",
		"part": map[string]interface{}{
			"type": "text",
			"text": "first line\nsecond line",
		},
	})
	pane = rec.lastState.Panes["primary"]
	if pane.Activity != "first line" || len(pane.Recent) != 2 || pane.Recent[1] != "second line" {
		t.Fatalf("message part pane: %+v", pane)
	}

	openCodeHookEvent(t, r, sessionID, "session.idle", map[string]interface{}{
		"sessionID": "ses_mapping",
	})
	pane = rec.lastState.Panes["primary"]
	if pane.State != "done" || pane.Tool != "" || pane.LastKind != "session.idle" {
		t.Fatalf("final done pane: %+v", pane)
	}

	openCodeHookEvent(t, r, sessionID, "session.status", map[string]interface{}{
		"sessionID": "ses_mapping",
		"status":    map[string]interface{}{"type": "idle"},
	})
	pane = rec.lastState.Panes["primary"]
	if pane.State != "done" || pane.LastKind != "session.idle" {
		t.Fatalf("idle status must not demote fresh done pane: %+v", pane)
	}
}

func TestHookOpenCodeDoneUsesSharedDoneToIdleGrace(t *testing.T) {
	t.Setenv(state.StateRootEnv, t.TempDir())
	r, rec := newTestRunner(t)
	sessionID := "qm-opencode-done-grace"
	cleanupRuntimeDir(t, sessionID)

	openCodeHookEvent(t, r, sessionID, "session.idle", map[string]interface{}{
		"sessionID": "ses_done_grace",
	})
	pane := rec.lastState.Panes["primary"]
	if pane.State != "done" {
		t.Fatalf("session.idle state = %q, want done", pane.State)
	}
	if err := state.SaveSessionState(sessionID, rec.lastState); err != nil {
		t.Fatalf("seed state: %v", err)
	}

	changed, err := state.MarkSessionObserved(sessionID, pane.LastEvent.Add(state.DoneToIdleGrace-time.Second))
	if err != nil {
		t.Fatalf("mark observed inside grace: %v", err)
	}
	if changed {
		t.Fatal("fresh done should remain visible inside DoneToIdleGrace")
	}

	changed, err = state.MarkSessionObserved(sessionID, pane.LastEvent.Add(state.DoneToIdleGrace+time.Second))
	if err != nil {
		t.Fatalf("mark observed after grace: %v", err)
	}
	if !changed {
		t.Fatal("stale done should fold to idle after DoneToIdleGrace")
	}
	got, err := state.LoadSessionState(sessionID)
	if err != nil {
		t.Fatalf("load state: %v", err)
	}
	if got.Panes["primary"].State != "idle" {
		t.Fatalf("state after grace = %q, want idle", got.Panes["primary"].State)
	}
}

func TestHookOpenCodeMapsSessionErrorToBlocked(t *testing.T) {
	r, rec := newTestRunner(t)
	sessionID := "qm-opencode-error"
	cleanupRuntimeDir(t, sessionID)
	openCodeHookEvent(t, r, sessionID, "session.error", map[string]interface{}{
		"sessionID": "ses_error",
		"message":   "simulated provider error",
	})
	pane := rec.lastState.Panes["primary"]
	if pane.State != "blocked" || pane.Activity != "Error: simulated provider error" {
		t.Fatalf("error pane: %+v", pane)
	}
}

func TestHookOpenCodeMalformedPayloadIsNoOp(t *testing.T) {
	r, rec := newTestRunner(t)
	stderr := runOpenCodeHookRaw(r, "qm-opencode-malformed", []byte(`{"event":`))
	if !strings.Contains(stderr, "malformed payload") {
		t.Fatalf("stderr = %q, want malformed payload", stderr)
	}
	if rec.lastState != nil || len(rec.events) != 0 {
		t.Fatalf("malformed payload should not mutate state/events: state=%+v events=%+v", rec.lastState, rec.events)
	}
}

func TestHookOpenCodeToolAfterDoesNotRegressIdleState(t *testing.T) {
	r, rec := newTestRunner(t)
	sessionID := "qm-opencode-out-of-order"
	cleanupRuntimeDir(t, sessionID)
	openCodeHookEvent(t, r, sessionID, "session.idle", map[string]interface{}{
		"sessionID": "ses_ooo",
	})
	openCodeHookEvent(t, r, sessionID, "tool.execute.after", map[string]interface{}{
		"sessionID": "ses_ooo",
		"tool":      "bash",
	})
	pane := rec.lastState.Panes["primary"]
	if pane.State != "done" {
		t.Fatalf("out-of-order tool.after state = %q, want done (pane=%+v)", pane.State, pane)
	}
}

func openCodeHookEvent(t *testing.T, r *HookRunner, sessionID, eventType string, properties map[string]interface{}) {
	t.Helper()
	event := openCodeEvent{
		ID:         "evt_" + strings.ReplaceAll(eventType, ".", "_"),
		Type:       eventType,
		Properties: properties,
	}
	stderr := runHookWithStdin(r, "opencode", "event", sessionID, openCodeHookPayload{
		Version: "phase2-v1",
		Event:   event,
	})
	if stderr != "" {
		t.Fatalf("%s stderr: %q", eventType, stderr)
	}
}

func runOpenCodeHookRaw(r *HookRunner, sessionID string, payload []byte) string {
	var buf bytes.Buffer
	runHook(r, hookOptions{agent: "opencode", action: "event", session: sessionID, stdin: payload}, &buf)
	return buf.String()
}

func openCodeFixtureEvent(t *testing.T, eventType string) []byte {
	t.Helper()
	path := filepath.Join("..", "spikes", "opencode-harness", "fixtures", "real-opencode-1.17.11", "initial-events.ndjson")
	f, err := os.Open(path)
	if err != nil {
		t.Fatalf("open fixture: %v", err)
	}
	defer f.Close()
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := bytes.TrimSpace(scanner.Bytes())
		if len(line) == 0 {
			continue
		}
		var rec struct {
			Event struct {
				Type string `json:"type"`
			} `json:"event"`
		}
		if err := json.Unmarshal(line, &rec); err != nil {
			t.Fatalf("decode fixture line: %v", err)
		}
		if rec.Event.Type == eventType {
			return append([]byte(nil), line...)
		}
	}
	if err := scanner.Err(); err != nil {
		t.Fatalf("scan fixture: %v", err)
	}
	t.Fatalf("fixture event %q not found", eventType)
	return nil
}

func cleanupRuntimeDir(t *testing.T, sessionID string) {
	t.Helper()
	runtimeDir := filepath.Join("/tmp", sessionID)
	_ = os.RemoveAll(runtimeDir)
	t.Cleanup(func() { _ = os.RemoveAll(runtimeDir) })
}
