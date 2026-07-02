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
	"github.com/alexivison/questmaster/internal/tmux"
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

func TestHookOpenCodeSessionCreatedAdoptsAgentlessManifestAndTagsPane(t *testing.T) {
	r, _ := newTestRunner(t)
	sessionID := "qm-opencode-adopt"
	cleanupRuntimeDir(t, sessionID)
	t.Setenv("TMUX_PANE", "%9")
	store := newManifestStoreStub(sessionID, nil)
	tmuxStub := &tmuxEnvStub{}
	r.Store = store
	r.TmuxClient = tmuxStub

	openCodeHookEvent(t, r, sessionID, "session.created", map[string]interface{}{"sessionID": "ses_adopt"})
	openCodeHookEvent(t, r, sessionID, "session.created", map[string]interface{}{"sessionID": "ses_adopt"})

	if store.updateCalls != 1 {
		t.Fatalf("manifest updates: got %d, want 1", store.updateCalls)
	}
	if len(store.manifest.Agents) != 1 {
		t.Fatalf("agents = %+v, want one adopted agent", store.manifest.Agents)
	}
	agent := store.manifest.Agents[0]
	if agent.Name != "opencode" || agent.Role != "primary" || agent.CLI != "opencode" ||
		agent.ResumeID != "ses_adopt" || agent.Window != tmux.WindowWorkspace {
		t.Fatalf("adopted agent = %+v", agent)
	}
	if got := store.manifest.ExtraString("opencode_session_id"); got != "ses_adopt" {
		t.Fatalf("opencode_session_id: got %q, want ses_adopt", got)
	}
	if len(tmuxStub.paneOptionCalls) != 1 || tmuxStub.paneOptionCalls[0] != (tmuxPaneOptionCall{target: "%9", key: tmux.PaneRoleOption, value: tmux.RolePrimary}) {
		t.Fatalf("pane option calls: %+v", tmuxStub.paneOptionCalls)
	}
	if len(tmuxStub.calls) != 1 || tmuxStub.calls[0] != (tmuxEnvCall{session: sessionID, key: "OPENCODE_SESSION_ID", value: "ses_adopt"}) {
		t.Fatalf("tmux env calls: %+v", tmuxStub.calls)
	}
}

func TestHookOpenCodeAdoptsAgentlessManifestWithoutPaneTagOutsideTmux(t *testing.T) {
	r, _ := newTestRunner(t)
	sessionID := "qm-opencode-adopt-no-pane"
	cleanupRuntimeDir(t, sessionID)
	t.Setenv("TMUX_PANE", "")
	store := newManifestStoreStub(sessionID, nil)
	tmuxStub := &tmuxEnvStub{}
	r.Store = store
	r.TmuxClient = tmuxStub

	openCodeHookEvent(t, r, sessionID, "session.created", map[string]interface{}{"sessionID": "ses_no_pane"})

	if len(store.manifest.Agents) != 1 || store.manifest.Agents[0].Name != "opencode" {
		t.Fatalf("agents = %+v, want adopted opencode", store.manifest.Agents)
	}
	if len(tmuxStub.paneOptionCalls) != 0 {
		t.Fatalf("pane option calls: %+v", tmuxStub.paneOptionCalls)
	}
}

func TestHookOpenCodeLeavesPersistedAgentManifestUntouched(t *testing.T) {
	r, _ := newTestRunner(t)
	sessionID := "qm-opencode-existing"
	cleanupRuntimeDir(t, sessionID)
	t.Setenv("TMUX_PANE", "%9")
	store := newManifestStoreStub(sessionID, map[string]string{"opencode_session_id": "ses_existing"})
	store.manifest.Agents = []state.AgentManifest{{
		Name: "opencode", Role: "primary", CLI: "opencode", ResumeID: "ses_existing", Window: tmux.WindowWorkspace,
	}}
	tmuxStub := &tmuxEnvStub{}
	r.Store = store
	r.TmuxClient = tmuxStub
	before, err := json.Marshal(store.manifest)
	if err != nil {
		t.Fatalf("marshal before: %v", err)
	}

	openCodeHookEvent(t, r, sessionID, "session.created", map[string]interface{}{"sessionID": "ses_existing"})

	after, err := json.Marshal(store.manifest)
	if err != nil {
		t.Fatalf("marshal after: %v", err)
	}
	if !bytes.Equal(after, before) {
		t.Fatalf("manifest changed\nbefore: %s\nafter:  %s", before, after)
	}
	if store.updateCalls != 0 {
		t.Fatalf("manifest updates: got %d, want 0", store.updateCalls)
	}
	if len(tmuxStub.paneOptionCalls) != 0 {
		t.Fatalf("pane option calls: %+v", tmuxStub.paneOptionCalls)
	}
}

func TestHookOpenCodeLeavesDifferentAgentManifestUntouched(t *testing.T) {
	r, _ := newTestRunner(t)
	sessionID := "qm-opencode-existing-other"
	cleanupRuntimeDir(t, sessionID)
	t.Setenv("TMUX_PANE", "%9")
	store := newManifestStoreStub(sessionID, nil)
	store.manifest.Agents = []state.AgentManifest{{
		Name: "codex", Role: "primary", CLI: "codex", ResumeID: "codex-thread-1", Window: tmux.WindowWorkspace,
	}}
	tmuxStub := &tmuxEnvStub{}
	r.Store = store
	r.TmuxClient = tmuxStub
	before, err := json.Marshal(store.manifest)
	if err != nil {
		t.Fatalf("marshal before: %v", err)
	}

	openCodeHookEvent(t, r, sessionID, "session.created", map[string]interface{}{"sessionID": "ses_opencode"})

	after, err := json.Marshal(store.manifest)
	if err != nil {
		t.Fatalf("marshal after: %v", err)
	}
	if !bytes.Equal(after, before) {
		t.Fatalf("manifest changed\nbefore: %s\nafter:  %s", before, after)
	}
	if store.updateCalls != 0 {
		t.Fatalf("manifest updates: got %d, want 0", store.updateCalls)
	}
	if len(tmuxStub.calls) != 0 || len(tmuxStub.paneOptionCalls) != 0 {
		t.Fatalf("tmux calls: env=%+v pane=%+v", tmuxStub.calls, tmuxStub.paneOptionCalls)
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
			"type":      "text",
			"text":      "first line\nsecond line",
			"messageID": "msg_assistant",
		},
	})
	pane = rec.lastState.Panes["primary"]
	if pane.Activity == "first line" {
		t.Fatalf("part text must not surface before message.updated confirms the role: %+v", pane)
	}

	openCodeHookEvent(t, r, sessionID, "message.updated", map[string]interface{}{
		"sessionID": "ses_mapping",
		"info":      map[string]interface{}{"id": "msg_assistant", "role": "assistant"},
	})
	pane = rec.lastState.Panes["primary"]
	if pane.Activity != "first line" || len(pane.Recent) != 2 || pane.Recent[1] != "second line" {
		t.Fatalf("assistant part pane after message.updated: %+v", pane)
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

func TestHookOpenCodeIgnoresOtherSessionIDsAfterAdoption(t *testing.T) {
	r, rec := newTestRunner(t)
	sessionID := "qm-opencode-one-session"
	cleanupRuntimeDir(t, sessionID)
	store := newManifestStoreStub(sessionID, nil)
	store.manifest.Agents = []state.AgentManifest{{Name: "opencode", Role: "primary", CLI: "opencode", Window: 1}}
	tmuxStub := &tmuxEnvStub{}
	r.Store = store
	r.TmuxClient = tmuxStub

	const current = "ses_current"
	const other = "ses_other"
	openCodeHookEvent(t, r, sessionID, "session.status", map[string]interface{}{
		"sessionID": current,
		"status":    map[string]interface{}{"type": "busy"},
	})
	pane := rec.lastState.Panes["primary"]
	if pane.State != "working" || pane.OpenCodeSessionID != current {
		t.Fatalf("initial pane: %+v", pane)
	}
	if got := store.manifest.ExtraString("opencode_session_id"); got != current {
		t.Fatalf("manifest opencode_session_id = %q, want %q", got, current)
	}
	writes := rec.writeCalls
	tmuxCalls := len(tmuxStub.calls)

	openCodeHookEvent(t, r, sessionID, "session.created", map[string]interface{}{"sessionID": other})
	openCodeHookEvent(t, r, sessionID, "session.status", map[string]interface{}{
		"sessionID": other,
		"status":    map[string]interface{}{"type": "busy"},
	})
	openCodeHookEvent(t, r, sessionID, "session.idle", map[string]interface{}{"sessionID": other})

	pane = rec.lastState.Panes["primary"]
	if pane.State != "working" || pane.Activity == "Session created" || pane.OpenCodeSessionID != current {
		t.Fatalf("foreign session mutated pane: %+v", pane)
	}
	if rec.writeCalls != writes {
		t.Fatalf("foreign session writes = %d, want %d", rec.writeCalls, writes)
	}
	if got := store.manifest.ExtraString("opencode_session_id"); got != current {
		t.Fatalf("foreign session updated manifest to %q, want %q", got, current)
	}
	if len(tmuxStub.calls) != tmuxCalls {
		t.Fatalf("foreign session tmux env calls = %+v, want unchanged length %d", tmuxStub.calls, tmuxCalls)
	}
}

func TestHookOpenCodeMapsReasoningAndToolParts(t *testing.T) {
	r, rec := newTestRunner(t)
	sessionID := "qm-opencode-parts"
	cleanupRuntimeDir(t, sessionID)
	const ocSession = "ses_parts"

	openCodeHookEvent(t, r, sessionID, "message.part.updated", map[string]interface{}{
		"sessionID": ocSession,
		"part": map[string]interface{}{
			"type":      "reasoning",
			"text":      "Let me search for that.",
			"messageID": "msg_assistant",
		},
	})
	pane := rec.lastState.Panes["primary"]
	if pane.State != "working" || pane.Activity != "Thinking: Let me search for that." {
		t.Fatalf("reasoning pane: %+v", pane)
	}

	openCodeHookEvent(t, r, sessionID, "message.part.updated", map[string]interface{}{
		"sessionID": ocSession,
		"part": map[string]interface{}{
			"type": "tool",
			"tool": "websearch",
			"state": map[string]interface{}{
				"status": "running",
				"input":  map[string]interface{}{"query": "interesting facts about Finland"},
			},
		},
	})
	pane = rec.lastState.Panes["primary"]
	if pane.State != "working" || pane.Tool != "websearch" || pane.Activity != "Web: interesting facts about Finland" {
		t.Fatalf("websearch pane: %+v", pane)
	}

	openCodeHookEvent(t, r, sessionID, "message.part.updated", map[string]interface{}{
		"sessionID": ocSession,
		"part": map[string]interface{}{
			"type": "tool",
			"tool": "bash",
			"state": map[string]interface{}{
				"status": "running",
				"input":  map[string]interface{}{"command": "rg status_view ~/.config/opencode"},
			},
		},
	})
	pane = rec.lastState.Panes["primary"]
	if pane.Tool != "bash" || pane.Activity != "Bash: rg status_view ~/.config/opencode" {
		t.Fatalf("bash running pane: %+v", pane)
	}

	openCodeHookEvent(t, r, sessionID, "message.part.updated", map[string]interface{}{
		"sessionID": ocSession,
		"part": map[string]interface{}{
			"type": "tool",
			"tool": "bash",
			"state": map[string]interface{}{
				"status": "completed",
				"input":  map[string]interface{}{"command": "rg status_view ~/.config/opencode"},
			},
		},
	})
	pane = rec.lastState.Panes["primary"]
	if pane.Tool != "" || pane.Activity != "Done: Bash: rg status_view ~/.config/opencode" {
		t.Fatalf("bash completed pane: %+v", pane)
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

func TestHookOpenCodeFixtureIgnoresUserPromptRecordsAssistantText(t *testing.T) {
	r, rec := newTestRunner(t)
	sessionID := "qm-opencode-role-fixture"
	cleanupRuntimeDir(t, sessionID)

	const userPromptPrefix = "Remember token QM_SPIKE_OK"
	for _, raw := range openCodeFixtureEventLines(t, "initial-events.ndjson") {
		if stderr := runOpenCodeHookRaw(r, sessionID, raw); stderr != "" {
			t.Fatalf("hook stderr: %q", stderr)
		}
		if rec.lastState == nil {
			continue
		}
		// At no point may the user's relayed prompt become the worker's activity.
		if got := rec.lastState.Panes["primary"].Activity; strings.HasPrefix(got, userPromptPrefix) {
			t.Fatalf("user prompt surfaced as activity: %q", got)
		}
	}

	pane := rec.lastState.Panes["primary"]
	if pane.Activity != "QM_SPIKE_OK" {
		t.Fatalf("final activity = %q, want assistant text QM_SPIKE_OK", pane.Activity)
	}
	if len(pane.Recent) != 1 || pane.Recent[0] != "QM_SPIKE_OK" {
		t.Fatalf("final recent = %#v, want [QM_SPIKE_OK]", pane.Recent)
	}
}

func openCodeFixtureEventLines(t *testing.T, fileName string) [][]byte {
	t.Helper()
	path := filepath.Join("testdata", "opencode-1.17.11", fileName)
	f, err := os.Open(path)
	if err != nil {
		t.Fatalf("open fixture: %v", err)
	}
	defer f.Close()
	var lines [][]byte
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
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
		if err := json.Unmarshal(line, &rec); err != nil || rec.Event.Type == "" {
			continue
		}
		lines = append(lines, append([]byte(nil), line...))
	}
	if err := scanner.Err(); err != nil {
		t.Fatalf("scan fixture: %v", err)
	}
	if len(lines) == 0 {
		t.Fatalf("fixture %q had no events", fileName)
	}
	return lines
}

func openCodeFixtureEvent(t *testing.T, eventType string) []byte {
	t.Helper()
	path := filepath.Join("testdata", "opencode-1.17.11", "initial-events.ndjson")
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
