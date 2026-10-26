package cmd

import (
	"bufio"
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
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
	store.manifest.Agents = []state.AgentManifest{{Name: "opencode", Role: "agent", CLI: "opencode", Window: 1}}
	tmuxStub := &tmuxEnvStub{}
	r.Store = store
	r.TmuxClient = tmuxStub

	raw := openCodeFixtureEvent(t, "session.created")
	stderr := runOpenCodeHookRaw(r, sessionID, raw)
	if stderr != "" {
		t.Fatalf("stderr: %q", stderr)
	}

	pane := rec.lastState.Panes["agent"]
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
	store.manifest.Cwd = "/old"
	adoptedCwd := t.TempDir()
	t.Chdir(adoptedCwd)
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
	if agent.Name != "opencode" || agent.Role != "agent" || agent.CLI != "opencode" ||
		agent.ResumeID != "ses_adopt" || agent.Window != tmux.WindowWorkspace {
		t.Fatalf("adopted agent = %+v", agent)
	}
	if got := store.manifest.ExtraString("opencode_session_id"); got != "ses_adopt" {
		t.Fatalf("opencode_session_id: got %q, want ses_adopt", got)
	}
	if got := store.manifest.ExtraString("adopted_pane"); got != "%9" {
		t.Fatalf("adopted_pane: got %q, want %%9", got)
	}
	if store.manifest.Cwd != adoptedCwd {
		t.Fatalf("adopted cwd = %q, want %q", store.manifest.Cwd, adoptedCwd)
	}
	if len(tmuxStub.paneOptionCalls) != 1 || tmuxStub.paneOptionCalls[0] != (tmuxPaneOptionCall{target: "%9", key: tmux.PaneRoleOption, value: tmux.RoleAgent}) {
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
	if !manifestHasExtra(store.manifest, "adopted_pane") || store.manifest.ExtraString("adopted_pane") != "" {
		t.Fatalf("adopted_pane should be recorded empty outside tmux, extras=%+v", store.manifest.Extra)
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
		Name: "opencode", Role: "agent", CLI: "opencode", ResumeID: "ses_existing", Window: tmux.WindowWorkspace,
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
		Name: "codex", Role: "agent", CLI: "codex", ResumeID: "codex-thread-1", Window: tmux.WindowWorkspace,
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

func TestHookOpenCodeSamePaneSuccession(t *testing.T) {
	r, _ := newTestRunner(t)
	sessionID := "qm-opencode-succession"
	cleanupRuntimeDir(t, sessionID)
	t.Setenv("TMUX_PANE", "%9")
	store := newManifestStoreStub(sessionID, map[string]string{
		"adopted_pane":    "%9",
		"codex_thread_id": "codex-thread-1",
	})
	store.manifest.Cwd = "/old"
	store.manifest.Agents = []state.AgentManifest{{
		Name: "codex", Role: "agent", CLI: "codex", ResumeID: "codex-thread-1", Window: tmux.WindowWorkspace,
	}}
	newCwd := t.TempDir()
	t.Chdir(newCwd)
	tmuxStub := &tmuxEnvStub{}
	r.Store = store
	r.TmuxClient = tmuxStub

	openCodeHookEvent(t, r, sessionID, "session.created", map[string]interface{}{"sessionID": "ses_opencode"})
	openCodeHookEvent(t, r, sessionID, "session.created", map[string]interface{}{"sessionID": "ses_opencode"})

	if len(store.manifest.Agents) != 1 {
		t.Fatalf("agents = %+v, want one successor", store.manifest.Agents)
	}
	agent := store.manifest.Agents[0]
	if agent.Name != "opencode" || agent.Role != "agent" || agent.CLI != "opencode" ||
		agent.ResumeID != "ses_opencode" || agent.Window != tmux.WindowWorkspace {
		t.Fatalf("successor agent = %+v", agent)
	}
	if store.manifest.Cwd != newCwd {
		t.Fatalf("cwd = %q, want %q", store.manifest.Cwd, newCwd)
	}
	if got := store.manifest.ExtraString("adopted_pane"); got != "%9" {
		t.Fatalf("adopted_pane: got %q, want %%9", got)
	}
	if got := store.manifest.ExtraString("opencode_session_id"); got != "ses_opencode" {
		t.Fatalf("opencode_session_id: got %q, want ses_opencode", got)
	}
	if got := store.manifest.ExtraString("title_provisional"); got != "1" {
		t.Fatalf("title_provisional: got %q, want 1", got)
	}
	if store.updateCalls != 1 {
		t.Fatalf("manifest updates: got %d, want one succession update", store.updateCalls)
	}
	if len(tmuxStub.calls) != 1 || tmuxStub.calls[0] != (tmuxEnvCall{session: sessionID, key: "OPENCODE_SESSION_ID", value: "ses_opencode"}) {
		t.Fatalf("tmux env calls: %+v", tmuxStub.calls)
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
	pane := rec.lastState.Panes["agent"]
	if pane.State != "working" {
		t.Fatalf("busy state = %q, want working", pane.State)
	}

	openCodeHookEvent(t, r, sessionID, "tool.execute.before", map[string]interface{}{
		"sessionID": "ses_mapping",
		"tool":      "bash",
	})
	pane = rec.lastState.Panes["agent"]
	if pane.State != "working" || pane.Tool != "bash" || pane.Activity != "Tool: bash" {
		t.Fatalf("tool before pane: %+v", pane)
	}

	openCodeHookEvent(t, r, sessionID, "permission.asked", map[string]interface{}{
		"sessionID":  "ses_mapping",
		"permission": map[string]interface{}{"id": "perm_bash", "tool": "bash"},
	})
	pane = rec.lastState.Panes["agent"]
	if pane.State != "blocked" || pane.Activity != "Permission: perm_bash" {
		t.Fatalf("permission pane: %+v", pane)
	}

	openCodeHookEvent(t, r, sessionID, "session.idle", map[string]interface{}{
		"sessionID": "ses_mapping",
	})
	pane = rec.lastState.Panes["agent"]
	if pane.State != "blocked" {
		t.Fatalf("idle must not clear permission block: %+v", pane)
	}

	openCodeHookEvent(t, r, sessionID, "permission.replied", map[string]interface{}{
		"sessionID":  "ses_mapping",
		"permission": map[string]interface{}{"id": "perm_bash", "action": "allow"},
	})
	pane = rec.lastState.Panes["agent"]
	if pane.State != "working" || pane.Activity != "Permission replied" {
		t.Fatalf("permission replied pane: %+v", pane)
	}

	openCodeHookEvent(t, r, sessionID, "tool.execute.after", map[string]interface{}{
		"sessionID": "ses_mapping",
		"tool":      "bash",
	})
	pane = rec.lastState.Panes["agent"]
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
	pane = rec.lastState.Panes["agent"]
	if pane.Activity == "first line" {
		t.Fatalf("part text must not surface before message.updated confirms the role: %+v", pane)
	}

	openCodeHookEvent(t, r, sessionID, "message.updated", map[string]interface{}{
		"sessionID": "ses_mapping",
		"info":      map[string]interface{}{"id": "msg_assistant", "role": "assistant"},
	})
	pane = rec.lastState.Panes["agent"]
	if pane.Activity != "first line" || len(pane.Recent) != 2 || pane.Recent[1] != "second line" {
		t.Fatalf("assistant part pane after message.updated: %+v", pane)
	}

	openCodeHookEvent(t, r, sessionID, "session.idle", map[string]interface{}{
		"sessionID": "ses_mapping",
	})
	pane = rec.lastState.Panes["agent"]
	if pane.State != "done" || pane.Tool != "" || pane.LastKind != "session.idle" {
		t.Fatalf("final done pane: %+v", pane)
	}

	openCodeHookEvent(t, r, sessionID, "session.status", map[string]interface{}{
		"sessionID": "ses_mapping",
		"status":    map[string]interface{}{"type": "idle"},
	})
	pane = rec.lastState.Panes["agent"]
	if pane.State != "done" || pane.LastKind != "session.idle" {
		t.Fatalf("idle status must not demote fresh done pane: %+v", pane)
	}
}

func TestHookOpenCodeFeedEntriesAndRejectedEvents(t *testing.T) {
	r, rec := newTestRunner(t)
	sessionID := "qm-opencode-feed"
	cleanupRuntimeDir(t, sessionID)
	const ocSession = "ses_feed"

	openCodeHookEvent(t, r, sessionID, "tool.execute.before", map[string]interface{}{
		"sessionID": ocSession,
		"tool":      "bash",
	})
	toolEvent := rec.events[len(rec.events)-1]
	if got := chatKinds(toolEvent); !slices.Equal(got, []string{"status", "action"}) {
		t.Fatalf("tool feed kinds = %v", got)
	}
	if toolEvent.Fields["chat_summary"] != nil || toolEvent.Fields["workerfeed_part_text"] != nil {
		t.Fatalf("redundant OpenCode feed fields: %#v", toolEvent.Fields)
	}
	writes := rec.writeCalls
	events := len(rec.events)
	openCodeHookEvent(t, r, sessionID, "tool.execute.before", map[string]interface{}{
		"sessionID": "ses_child", "tool": "bash",
	})
	openCodeHookEvent(t, r, sessionID, "session.idle", map[string]interface{}{"sessionID": "ses_child"})
	if rec.writeCalls != writes || len(rec.events) != events {
		t.Fatalf("rejected child events changed state/log: writes=%d events=%d, want %d/%d", rec.writeCalls, len(rec.events), writes, events)
	}

	finalText := "full OpenCode final message\nsecond line"
	openCodeHookEvent(t, r, sessionID, "message.part.updated", map[string]interface{}{
		"sessionID": ocSession,
		"part": map[string]interface{}{
			"type": "text", "text": finalText, "messageID": "msg_final",
		},
	})
	openCodeHookEvent(t, r, sessionID, "message.updated", map[string]interface{}{
		"sessionID": ocSession,
		"info":      map[string]interface{}{"id": "msg_final", "role": "assistant"},
	})
	if got := rec.lastState.Panes["agent"].PendingFinalMessage; got != finalText {
		t.Fatalf("pending OpenCode final message = %q", got)
	}
	openCodeHookEvent(t, r, sessionID, "session.idle", map[string]interface{}{"sessionID": ocSession})
	finalEvent := rec.events[len(rec.events)-1]
	if chatTextFor(finalEvent, "message") != finalText || !slices.Contains(chatKinds(finalEvent), "status") {
		t.Fatalf("OpenCode final feed event = %+v", finalEvent)
	}
	if rec.lastState.Panes["agent"].PendingFinalMessage != "" {
		t.Fatal("OpenCode final message was not cleared after done")
	}

	openCodeHookEvent(t, r, sessionID, "permission.asked", map[string]interface{}{
		"sessionID":  ocSession,
		"permission": map[string]interface{}{"id": "perm_feed", "tool": "bash"},
	})
	openCodeHookEvent(t, r, sessionID, "session.idle", map[string]interface{}{"sessionID": ocSession})
	permissionIdle := rec.events[len(rec.events)-1]
	if len(chatEntries(permissionIdle)) != 0 || rec.lastState.Panes["agent"].State != "blocked" {
		t.Fatalf("idle during permission emitted chat or cleared block: event=%+v pane=%+v", permissionIdle, rec.lastState.Panes["agent"])
	}
}

func TestHookOpenCodeIgnoresOtherSessionIDsAfterAdoption(t *testing.T) {
	r, rec := newTestRunner(t)
	sessionID := "qm-opencode-one-session"
	cleanupRuntimeDir(t, sessionID)
	store := newManifestStoreStub(sessionID, nil)
	store.manifest.Agents = []state.AgentManifest{{Name: "opencode", Role: "agent", CLI: "opencode", Window: 1}}
	tmuxStub := &tmuxEnvStub{}
	r.Store = store
	r.TmuxClient = tmuxStub

	const current = "ses_current"
	const other = "ses_other"
	openCodeHookEvent(t, r, sessionID, "session.status", map[string]interface{}{
		"sessionID": current,
		"status":    map[string]interface{}{"type": "busy"},
	})
	pane := rec.lastState.Panes["agent"]
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

	pane = rec.lastState.Panes["agent"]
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

func TestHookOpenCodeNeverRoutesChildEventsThroughParentPane(t *testing.T) {
	t.Parallel()
	r, rec := newParallelHookRunner()
	sessionID := "qm-opencode-child-events"
	rec.lastState = &state.SessionState{
		SessionID: sessionID, Version: state.SchemaVersion,
		Panes: map[string]state.PaneState{"agent": {Role: "agent", Agent: "opencode", State: "done", OpenCodeSessionID: "ses_root"}},
	}

	openCodeHookEvent(t, r, sessionID, "session.created", map[string]interface{}{"info": map[string]interface{}{
		"id": "ses_child", "parentID": "ses_root", "agent": "Explore",
	}})
	rootPane := rec.lastState.Panes["agent"]
	if rootPane.OpenCodeSessionID != "ses_root" || rootPane.State != "done" {
		t.Fatalf("child creation changed root pane: %+v", rootPane)
	}
	writes, events := rec.writeCalls, len(rec.events)
	for _, event := range []struct {
		kind  string
		props map[string]interface{}
	}{
		{"session.status", map[string]interface{}{"sessionID": "ses_child", "status": map[string]interface{}{"type": "busy"}}},
		{"tool.execute.before", map[string]interface{}{"sessionID": "ses_child", "tool": "bash", "callID": "child-call"}},
		{"session.idle", map[string]interface{}{"sessionID": "ses_child"}},
	} {
		openCodeHookEvent(t, r, sessionID, event.kind, event.props)
	}
	rootPane = rec.lastState.Panes["agent"]
	if rootPane.OpenCodeSessionID != "ses_root" || rootPane.State != "done" {
		t.Fatalf("child event changed root pane: %+v", rootPane)
	}
	if rec.writeCalls != writes || len(rec.events) != events {
		t.Fatalf("child event writes/events = %d/%d, want %d/%d", rec.writeCalls, len(rec.events), writes, events)
	}
}

func TestHookOpenCodeIgnoresUnknownChildIdleBeforeCreated(t *testing.T) {
	t.Parallel()
	r, rec := newParallelHookRunner()
	sessionID := "qm-opencode-unknown-child"
	rec.lastState = &state.SessionState{
		SessionID: sessionID, Version: state.SchemaVersion,
		Panes: map[string]state.PaneState{"agent": {Role: "agent", Agent: "opencode", State: "working", OpenCodeSessionID: "ses_root"}},
	}

	openCodeHookEvent(t, r, sessionID, "session.idle", map[string]interface{}{"sessionID": "ses_child"})
	pane := rec.lastState.Panes["agent"]
	if pane.State != "working" || pane.OpenCodeSessionID != "ses_root" {
		t.Fatalf("unknown child's idle changed parent pane: %+v", pane)
	}
}

func TestHookOpenCodeRootChangeClearsActiveChildren(t *testing.T) {
	t.Parallel()
	r, rec := newParallelHookRunner()
	sessionID := "qm-opencode-root-change"
	now := time.Date(2026, 10, 26, 0, 0, 0, 0, time.UTC)
	rec.lastState = &state.SessionState{
		SessionID: sessionID, Version: state.SchemaVersion,
		Panes: map[string]state.PaneState{"agent": {
			Role: "agent", Agent: "opencode", State: "done", OpenCodeSessionID: "ses_old",
			ActiveSubagents:         map[string]string{"ses_child": "Explore"},
			ActiveSubagentStartedAt: map[string]time.Time{"ses_child": now},
		}},
	}

	openCodeHookEvent(t, r, sessionID, "session.created", map[string]interface{}{"info": map[string]interface{}{"id": "ses_new"}})
	pane := rec.lastState.Panes["agent"]
	if pane.OpenCodeSessionID != "ses_new" || pane.State != "starting" {
		t.Fatalf("root session after transition = %+v", pane)
	}
	if len(pane.ActiveSubagents) != 0 || len(pane.ActiveSubagentStartedAt) != 0 {
		t.Fatalf("old-root children survived root transition: active=%v started=%v", pane.ActiveSubagents, pane.ActiveSubagentStartedAt)
	}
}

func TestOpenCodeTaskFinishCorrelation(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name  string
		event openCodeEvent
		want  string
	}{
		{
			name: "foreground task result",
			event: openCodeEvent{Type: "tool.execute.after", Properties: map[string]interface{}{
				"tool": "task", "metadata": map[string]interface{}{"sessionId": "ses_child"},
			}},
			want: "ses_child",
		},
		{
			name: "background task starts without finishing",
			event: openCodeEvent{Type: "tool.execute.after", Properties: map[string]interface{}{
				"tool": "task", "metadata": map[string]interface{}{"sessionId": "ses_child", "background": true},
			}},
		},
		{
			name: "completed task tool part",
			event: openCodeEvent{Type: "message.part.updated", Properties: map[string]interface{}{"part": map[string]interface{}{
				"type": "tool", "tool": "task", "state": map[string]interface{}{
					"status": "completed", "metadata": map[string]interface{}{"sessionId": "ses_child"},
				},
			}}},
			want: "ses_child",
		},
		{
			name: "failed task tool part",
			event: openCodeEvent{Type: "message.part.updated", Properties: map[string]interface{}{"part": map[string]interface{}{
				"type": "tool", "tool": "task", "state": map[string]interface{}{
					"status": "error", "metadata": map[string]interface{}{"sessionId": "ses_child"},
				},
			}}},
			want: "ses_child",
		},
		{
			name: "background result",
			event: openCodeEvent{Type: "message.part.updated", Properties: map[string]interface{}{"part": map[string]interface{}{
				"type": "text", "synthetic": true,
				"text": `<task id="ses_child" state="completed">result</task>`,
			}}},
			want: "ses_child",
		},
		{
			name: "unrelated tool result",
			event: openCodeEvent{Type: "tool.execute.after", Properties: map[string]interface{}{
				"tool": "bash", "metadata": map[string]interface{}{"sessionId": "ses_child"},
			}},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			if got := openCodeTaskResultSessionID(tc.event); got != tc.want {
				t.Fatalf("finish session id = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestHookOpenCodeDismissesBackgroundChildOnCorrelatedResult(t *testing.T) {
	t.Parallel()
	r, rec := newParallelHookRunner()
	sessionID := "qm-opencode-background-finish"
	rec.lastState = &state.SessionState{
		SessionID: sessionID, Version: state.SchemaVersion,
		Panes: map[string]state.PaneState{"agent": {Role: "agent", Agent: "opencode", State: "working", OpenCodeSessionID: "ses_root"}},
	}
	openCodeHookEvent(t, r, sessionID, "session.created", map[string]interface{}{"info": map[string]interface{}{
		"id": "ses_child", "parentID": "ses_root", "agent": "Explore",
	}})
	openCodeHookEvent(t, r, sessionID, "tool.execute.after", map[string]interface{}{
		"sessionID": "ses_root", "tool": "task",
		"metadata": map[string]interface{}{"sessionId": "ses_child", "background": true},
	})
	if got := chatKinds(latestHookEvent(t, rec)); slices.Contains(got, "dismiss") {
		t.Fatalf("background start dismissed child: %v", got)
	}
	openCodeHookEvent(t, r, sessionID, "message.part.updated", map[string]interface{}{
		"sessionID": "ses_root", "part": map[string]interface{}{
			"type": "text", "synthetic": true,
			"text": `<task id="ses_child" state="completed">result</task>`,
		},
	})
	assertSubagentChat(t, latestHookEvent(t, rec), "dismiss", "Explore")
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
	pane := rec.lastState.Panes["agent"]
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
	pane = rec.lastState.Panes["agent"]
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
	pane = rec.lastState.Panes["agent"]
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
	pane = rec.lastState.Panes["agent"]
	if pane.Tool != "" || pane.Activity != "Done: Bash: rg status_view ~/.config/opencode" {
		t.Fatalf("bash completed pane: %+v", pane)
	}
}

func TestHookOpenCodeCompletedPartDoesNotClearParallelToolCasts(t *testing.T) {
	r, rec := newTestRunner(t)
	const sessionID = "qm-opencode-parallel-casts"
	const ocSession = "ses_parallel"
	for _, call := range []struct {
		id   string
		tool string
	}{
		{id: "call-1", tool: "bash"},
		{id: "call-2", tool: "read"},
	} {
		openCodeHookEvent(t, r, sessionID, "tool.execute.before", map[string]interface{}{
			"tool": call.tool, "sessionID": ocSession, "callID": call.id,
			"args": map[string]interface{}{"command": "go test ./..."},
		})
	}
	if got := len(rec.lastState.Panes["agent"].RunningTools); got != 2 {
		t.Fatalf("running tools before part update = %d, want 2", got)
	}

	openCodeHookEvent(t, r, sessionID, "message.part.updated", map[string]interface{}{
		"sessionID": ocSession,
		"part": map[string]interface{}{
			"id": "call-1", "type": "tool", "tool": "bash",
			"state": map[string]interface{}{"status": "completed", "input": map[string]interface{}{"command": "go test ./..."}},
		},
	})
	pane := rec.lastState.Panes["agent"]
	if len(pane.RunningTools) != 2 || pane.Tool != "read" {
		t.Fatalf("completed part cleared parallel casts or lost fallback: %+v", pane)
	}

	openCodeHookEvent(t, r, sessionID, "tool.execute.after", map[string]interface{}{
		"tool": "bash", "sessionID": ocSession, "callID": "call-1",
	})
	pane = rec.lastState.Panes["agent"]
	if len(pane.RunningTools) != 1 || pane.RunningTools[0].CallID != "call-2" || pane.Tool != "read" {
		t.Fatalf("tool after did not preserve the parallel cast: %+v", pane)
	}
}

func TestHookOpenCodeErrorPartEndsCallWithoutLearningDuration(t *testing.T) {
	r, rec := newTestRunner(t)
	const sessionID = "qm-opencode-error-call"
	const ocSession = "ses_error"
	var durations []toolDurationCall
	r.RecordToolDuration = func(agent, tool, command string, duration time.Duration) error {
		durations = append(durations, toolDurationCall{agent: agent, tool: tool, command: command, duration: duration})
		return nil
	}
	openCodeHookEvent(t, r, sessionID, "tool.execute.before", map[string]interface{}{
		"tool": "bash", "sessionID": ocSession, "callID": "call-1",
		"args": map[string]interface{}{"command": "go test ./..."},
	})
	openCodeHookEvent(t, r, sessionID, "message.part.updated", map[string]interface{}{
		"sessionID": ocSession,
		"part": map[string]interface{}{
			"id": "prt-1", "callID": "call-1", "type": "tool", "tool": "bash",
			"state": map[string]interface{}{"status": "error", "input": map[string]interface{}{"command": "go test ./..."}},
		},
	})
	pane := rec.lastState.Panes["agent"]
	if pane.Tool != "" || len(pane.RunningTools) != 0 || !strings.HasPrefix(pane.Activity, "Failed: ") {
		t.Fatalf("failed tool part pane = %+v, want call ended without stale cast", pane)
	}
	if len(durations) != 0 {
		t.Fatalf("failed tool recorded durations = %+v, want none", durations)
	}
}

func TestHookOpenCodeOutOfOrderAfterBeforeNeedsPluginSerialization(t *testing.T) {
	r, rec := newTestRunner(t)
	const sessionID = "qm-opencode-out-of-order"
	const ocSession = "ses_out_of_order"
	openCodeHookEvent(t, r, sessionID, "tool.execute.after", map[string]interface{}{
		"tool": "bash", "sessionID": ocSession, "callID": "call-1",
	})
	openCodeHookEvent(t, r, sessionID, "tool.execute.before", map[string]interface{}{
		"tool": "bash", "sessionID": ocSession, "callID": "call-1",
	})
	if pane := rec.lastState.Panes["agent"]; len(pane.RunningTools) != 1 || pane.Tool != "bash" {
		t.Fatalf("out-of-order events = %+v, want a stale cast (plugin queue prevents this live)", pane)
	}
}

func TestHookOpenCodeDoneUsesSharedDoneToIdleGrace(t *testing.T) {
	t.Setenv(state.StateRootEnv, t.TempDir())
	r, rec := newTestRunner(t)
	sessionID := "qm-opencode-done-grace"
	cleanupRuntimeDir(t, sessionID)

	openCodeHookEvent(t, r, sessionID, "session.created", map[string]interface{}{"info": map[string]interface{}{"id": "ses_done_grace"}})
	openCodeHookEvent(t, r, sessionID, "session.idle", map[string]interface{}{
		"sessionID": "ses_done_grace",
	})
	pane := rec.lastState.Panes["agent"]
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
	if got.Panes["agent"].State != "idle" {
		t.Fatalf("state after grace = %q, want idle", got.Panes["agent"].State)
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
	pane := rec.lastState.Panes["agent"]
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
	openCodeHookEvent(t, r, sessionID, "session.created", map[string]interface{}{"info": map[string]interface{}{"id": "ses_ooo"}})
	openCodeHookEvent(t, r, sessionID, "session.idle", map[string]interface{}{
		"sessionID": "ses_ooo",
	})
	openCodeHookEvent(t, r, sessionID, "tool.execute.after", map[string]interface{}{
		"sessionID": "ses_ooo",
		"tool":      "bash",
	})
	pane := rec.lastState.Panes["agent"]
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

func TestHookOpenCodeUserPromptLeavesActivityUnchanged(t *testing.T) {
	r, rec := newTestRunner(t)
	const previousActivity = "previous activity"
	rec.lastState = &state.SessionState{
		SessionID: "qm-opencode-prompt",
		Version:   state.SchemaVersion,
		Panes: map[string]state.PaneState{
			"agent": {Role: "agent", Agent: "opencode", State: "starting", Activity: previousActivity},
		},
	}
	openCodeHookEvent(t, r, "qm-opencode-prompt", "session.status", map[string]interface{}{
		"status": map[string]interface{}{"type": "busy"},
	})
	openCodeHookEvent(t, r, "qm-opencode-prompt", "message.part.updated", map[string]interface{}{
		"part": map[string]interface{}{
			"type": "text", "text": "keep this prompt private", "messageID": "user-message",
		},
	})
	openCodeHookEvent(t, r, "qm-opencode-prompt", "message.updated", map[string]interface{}{
		"info": map[string]interface{}{"id": "user-message", "role": "user"},
	})
	pane := rec.lastState.Panes["agent"]
	if pane.State != "working" {
		t.Fatalf("state = %q, want working", pane.State)
	}
	if pane.Activity != previousActivity {
		t.Fatalf("activity = %q, want previous value %q", pane.Activity, previousActivity)
	}
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
		if got := rec.lastState.Panes["agent"].Activity; strings.HasPrefix(got, userPromptPrefix) {
			t.Fatalf("user prompt surfaced as activity: %q", got)
		}
	}

	pane := rec.lastState.Panes["agent"]
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
