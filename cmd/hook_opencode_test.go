package cmd

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"reflect"
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

func TestHookOpenCodeNativeSessionUpdatesRejectDelayedGeneration(t *testing.T) {
	r, rec := newTestRunner(t)
	sessionID := "qm-opencode-native-generation-order"
	t.Setenv("TMUX_PANE", "%9")
	store := newManifestStoreStub(sessionID, nil)
	store.manifest.Agents = []state.AgentManifest{{Name: "opencode", Role: "primary", CLI: "opencode", Window: tmux.WindowWorkspace}}
	tmuxStub := &tmuxEnvStub{paneIdentityPID: 4111}
	r.Store = store
	r.TmuxClient = tmuxStub

	openCodeHookEvent(t, r, sessionID, "session.updated", openCodeNativeSessionProperties(
		"ses_native_one", "questmaster-worker", "http://127.0.0.1:4111/", 4111, 1,
	))
	pane := rec.lastState.Panes["primary"]
	if pane.OpenCodeServerURL != "http://127.0.0.1:4111/" || pane.OpenCodePID != 4111 ||
		pane.OpenCodeSessionID != "ses_native_one" || pane.OpenCodeAgent != "questmaster-worker" {
		t.Fatalf("initial native pane = %+v", pane)
	}
	if got := store.manifest.ExtraString("opencode_session_id"); got != "ses_native_one" {
		t.Fatalf("initial manifest resume id = %q", got)
	}

	// A restarted OpenCode process may restart its source sequence. It only
	// replaces the current identity after the live pane has changed too.
	openCodeHookEvent(t, r, sessionID, "session.updated", openCodeNativeSessionProperties(
		"ses_native_two", "questmaster-master", "http://127.0.0.1:4222/", 4222, 1,
	))
	pane = rec.lastState.Panes["primary"]
	if pane.OpenCodeSessionID != "ses_native_one" || pane.OpenCodePID != 4111 {
		t.Fatalf("new pid without matching pane replaced identity: %+v", pane)
	}
	tmuxStub.paneIdentityPID = 4222
	openCodeHookEvent(t, r, sessionID, "session.updated", openCodeNativeSessionProperties(
		"ses_native_two", "questmaster-master", "http://127.0.0.1:4222/", 4222, 1,
	))
	pane = rec.lastState.Panes["primary"]
	if pane.OpenCodeServerURL != "http://127.0.0.1:4222/" || pane.OpenCodePID != 4222 ||
		pane.OpenCodeSessionID != "ses_native_two" || pane.OpenCodeAgent != "questmaster-master" {
		t.Fatalf("coherent replacement pane = %+v", pane)
	}
	if got := rec.events[len(rec.events)-1].Fields; got["opencode_server_url"] != "http://127.0.0.1:4222/" || got["opencode_pid"] != 4222 || got["opencode_agent"] != "questmaster-master" {
		t.Fatalf("native event fields = %+v", got)
	}
	if got := store.manifest.ExtraString("opencode_session_id"); got != "ses_native_two" {
		t.Fatalf("replacement manifest resume id = %q", got)
	}

	openCodeHookEvent(t, r, sessionID, "session.status", map[string]interface{}{
		"sessionID": "ses_native_two",
		"status":    map[string]interface{}{"type": "busy"},
		"metadata":  openCodeNativeMetadataProperties("http://127.0.0.1:4222/", 4222),
	})
	pane = rec.lastState.Panes["primary"]
	if pane.State != "working" || pane.OpenCodeSessionID != "ses_native_two" || pane.OpenCodePID != 4222 {
		t.Fatalf("matching generation status was not accepted: %+v", pane)
	}
	openCodeHookEvent(t, r, sessionID, "message.part.updated", map[string]interface{}{
		"sessionID": "ses_native_two",
		"part":      map[string]interface{}{"type": "text", "text": "hello", "messageID": "msg_b"},
		"metadata":  openCodeNativeMetadataProperties("http://127.0.0.1:4222/", 4222),
	})
	openCodeHookEvent(t, r, sessionID, "session.idle", map[string]interface{}{
		"sessionID": "ses_native_two",
		"metadata":  openCodeNativeMetadataProperties("http://127.0.0.1:4222/", 4222),
	})
	if len(tmuxStub.paneIdentityCalls) != 3 {
		t.Fatalf("ordinary native events queried pane identity: %+v", tmuxStub.paneIdentityCalls)
	}

	pane = rec.lastState.Panes["primary"]
	if pane.State != "done" {
		t.Fatalf("matching generation idle was not accepted: %+v", pane)
	}
	writes, manifestUpdates, envCalls := rec.writeCalls, store.updateCalls, len(tmuxStub.calls)
	wantPane, wantResumeID := pane, store.manifest.ExtraString("opencode_session_id")
	openCodeHookEvent(t, r, sessionID, "session.status", map[string]interface{}{
		"sessionID": "ses_native_one",
		"status":    map[string]interface{}{"type": "busy"},
		"metadata":  openCodeNativeMetadataProperties("http://127.0.0.1:4111/", 4111),
	})
	if len(tmuxStub.paneIdentityCalls) != 3 {
		t.Fatalf("delayed native status queried pane identity: %+v", tmuxStub.paneIdentityCalls)
	}
	pane = rec.lastState.Panes["primary"]
	if !reflect.DeepEqual(pane, wantPane) || store.manifest.ExtraString("opencode_session_id") != wantResumeID {
		t.Fatalf("delayed native status changed pane=%+v resume=%q, want pane=%+v resume=%q", pane, store.manifest.ExtraString("opencode_session_id"), wantPane, wantResumeID)
	}
	if rec.writeCalls != writes || store.updateCalls != manifestUpdates || len(tmuxStub.calls) != envCalls {
		t.Fatalf("delayed native status wrote state=%d/%d manifest=%d/%d env=%d/%d", rec.writeCalls, writes, store.updateCalls, manifestUpdates, len(tmuxStub.calls), envCalls)
	}

	openCodeHookEvent(t, r, sessionID, "session.updated", openCodeNativeSessionProperties(
		"ses_native_one", "questmaster-worker", "http://127.0.0.1:4111/", 4111, 1,
	))
	pane = rec.lastState.Panes["primary"]
	if pane.OpenCodeSessionID != "ses_native_two" || pane.OpenCodeAgent != "questmaster-master" || pane.OpenCodePID != 4222 {
		t.Fatalf("delayed generation replaced current identity: %+v", pane)
	}
	if rec.writeCalls != writes || store.updateCalls != manifestUpdates || len(tmuxStub.calls) != envCalls {
		t.Fatalf("delayed generation wrote state=%d/%d manifest=%d/%d env=%d/%d", rec.writeCalls, writes, store.updateCalls, manifestUpdates, len(tmuxStub.calls), envCalls)
	}
}

func TestHookOpenCodeNativeSessionUpdateOrdersSamePIDGenerations(t *testing.T) {
	r, rec := newTestRunner(t)
	sessionID := "qm-opencode-native-same-generation"
	cleanupRuntimeDir(t, sessionID)
	t.Setenv("TMUX_PANE", "%9")
	store := newManifestStoreStub(sessionID, nil)
	store.manifest.Agents = []state.AgentManifest{{Name: "opencode", Role: "primary", CLI: "opencode", Window: tmux.WindowWorkspace}}
	tmuxStub := &tmuxEnvStub{paneIdentityPID: 4111}
	r.Store = store
	r.TmuxClient = tmuxStub

	openCodeHookEvent(t, r, sessionID, "session.updated", openCodeNativeSessionProperties(
		"ses_native_one", "questmaster-worker", "http://127.0.0.1:4111/", 4111, 1,
	))
	openCodeHookEvent(t, r, sessionID, "session.updated", openCodeNativeSessionProperties(
		"ses_native_two", "questmaster-master", "http://127.0.0.1:4111/", 4111, 2,
	))
	pane := rec.lastState.Panes["primary"]
	if pane.OpenCodeSessionID != "ses_native_two" || pane.OpenCodeAgent != "questmaster-master" || pane.OpenCodePID != 4111 || pane.OpenCodeSessionUpdateSeq != 2 {
		t.Fatalf("same-generation session rotation = %+v", pane)
	}
	if got := store.manifest.ExtraString("opencode_session_id"); got != "ses_native_two" {
		t.Fatalf("manifest resume id = %q, want ses_native_two", got)
	}
	writes, manifestUpdates, envCalls := rec.writeCalls, store.updateCalls, len(tmuxStub.calls)
	data, err := os.ReadFile(filepath.Join("/tmp", sessionID, "opencode-session-id"))
	if err != nil || strings.TrimSpace(string(data)) != "ses_native_two" {
		t.Fatalf("runtime resume id before stale update = %q, %v", data, err)
	}

	openCodeHookEvent(t, r, sessionID, "session.updated", openCodeNativeSessionProperties(
		"ses_native_one", "questmaster-worker", "http://127.0.0.1:4111/", 4111, 1,
	))
	openCodeHookEvent(t, r, sessionID, "session.updated", openCodeNativeSessionProperties(
		"ses_native_three", "questmaster-worker", "http://127.0.0.1:4111/", 4111, 2,
	))
	pane = rec.lastState.Panes["primary"]
	if pane.OpenCodeSessionID != "ses_native_two" || pane.OpenCodeAgent != "questmaster-master" || pane.OpenCodePID != 4111 {
		t.Fatalf("stale or equal sequence replaced current identity: %+v", pane)
	}
	if rec.writeCalls != writes || store.updateCalls != manifestUpdates || len(tmuxStub.calls) != envCalls {
		t.Fatalf("stale or equal sequence wrote state=%d/%d manifest=%d/%d env=%d/%d", rec.writeCalls, writes, store.updateCalls, manifestUpdates, len(tmuxStub.calls), envCalls)
	}
	data, err = os.ReadFile(filepath.Join("/tmp", sessionID, "opencode-session-id"))
	if err != nil || strings.TrimSpace(string(data)) != "ses_native_two" {
		t.Fatalf("runtime resume id after stale update = %q, %v", data, err)
	}
}

func TestHookOpenCodeNativeSessionUpdateRequiresLiveCompleteMetadata(t *testing.T) {
	for _, tc := range []struct {
		name    string
		pane    string
		pid     int
		err     error
		lookups int
	}{
		{name: "missing pane", pane: "", pid: 4111},
		{name: "pane lookup fails", pane: "%9", pid: 4111, err: errors.New("no pane"), lookups: 1},
		{name: "pid mismatch", pane: "%9", pid: 9999, lookups: 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r, rec := newTestRunner(t)
			sessionID := "qm-opencode-native-reject"
			t.Setenv("TMUX_PANE", tc.pane)
			store := newManifestStoreStub(sessionID, nil)
			store.manifest.Agents = []state.AgentManifest{{Name: "opencode", Role: "primary", CLI: "opencode", Window: tmux.WindowWorkspace}}
			tmuxStub := &tmuxEnvStub{paneIdentityPID: tc.pid, paneIdentityErr: tc.err}
			r.Store = store
			r.TmuxClient = tmuxStub

			openCodeHookEvent(t, r, sessionID, "session.updated", openCodeNativeSessionProperties(
				"ses_native", "questmaster-worker", "http://127.0.0.1:4111/", 4111, 1,
			))
			if rec.lastState != nil || store.updateCalls != 0 || len(tmuxStub.calls) != 0 || len(tmuxStub.paneIdentityCalls) != tc.lookups {
				t.Fatalf("rejected native event changed state=%+v manifest=%d env=%+v", rec.lastState, store.updateCalls, tmuxStub.calls)
			}
		})
	}

	t.Run("incomplete metadata", func(t *testing.T) {
		r, rec := newTestRunner(t)
		sessionID := "qm-opencode-native-incomplete"
		t.Setenv("TMUX_PANE", "%9")
		store := newManifestStoreStub(sessionID, nil)
		store.manifest.Agents = []state.AgentManifest{{Name: "opencode", Role: "primary", CLI: "opencode", Window: tmux.WindowWorkspace}}
		tmuxStub := &tmuxEnvStub{paneIdentityPID: 4111}
		r.Store = store
		r.TmuxClient = tmuxStub

		openCodeHookEvent(t, r, sessionID, "session.updated", map[string]interface{}{
			"info":     map[string]interface{}{"id": "ses_native", "agent": "questmaster-worker"},
			"metadata": map[string]interface{}{"questmaster": map[string]interface{}{"server_url": "http://127.0.0.1:4111/"}},
		})
		if rec.lastState != nil || store.updateCalls != 0 || len(tmuxStub.paneIdentityCalls) != 0 || len(tmuxStub.calls) != 0 {
			t.Fatalf("incomplete native event changed state=%+v manifest=%d identity=%+v env=%+v", rec.lastState, store.updateCalls, tmuxStub.paneIdentityCalls, tmuxStub.calls)
		}
	})

	t.Run("invalid sequence", func(t *testing.T) {
		r, rec := newTestRunner(t)
		sessionID := "qm-opencode-native-invalid-sequence"
		t.Setenv("TMUX_PANE", "%9")
		store := newManifestStoreStub(sessionID, nil)
		store.manifest.Agents = []state.AgentManifest{{Name: "opencode", Role: "primary", CLI: "opencode", Window: tmux.WindowWorkspace}}
		tmuxStub := &tmuxEnvStub{paneIdentityPID: 4111}
		r.Store = store
		r.TmuxClient = tmuxStub

		props := openCodeNativeSessionProperties("ses_native", "questmaster-worker", "http://127.0.0.1:4111/", 4111, 1)
		props["metadata"].(map[string]interface{})["questmaster"].(map[string]interface{})["session_update_seq"] = float64(1<<53 + 1)
		openCodeHookEvent(t, r, sessionID, "session.updated", props)
		if rec.lastState != nil || store.updateCalls != 0 || len(tmuxStub.paneIdentityCalls) != 0 || len(tmuxStub.calls) != 0 {
			t.Fatalf("invalid sequence changed state=%+v manifest=%d identity=%+v env=%+v", rec.lastState, store.updateCalls, tmuxStub.paneIdentityCalls, tmuxStub.calls)
		}
	})
}

func TestHookOpenCodeNativeLifecycleCannotEstablishIdentity(t *testing.T) {
	r, rec := newTestRunner(t)
	sessionID := "qm-opencode-native-lifecycle-first"
	store := newManifestStoreStub(sessionID, nil)
	store.manifest.Agents = []state.AgentManifest{{Name: "opencode", Role: "primary", CLI: "opencode", Window: tmux.WindowWorkspace}}
	tmuxStub := &tmuxEnvStub{}
	r.Store = store
	r.TmuxClient = tmuxStub

	openCodeHookEvent(t, r, sessionID, "session.created", map[string]interface{}{
		"sessionID": "ses_native",
		"metadata":  openCodeNativeMetadataProperties("http://127.0.0.1:4111/", 4111),
	})
	openCodeHookEvent(t, r, sessionID, "session.status", map[string]interface{}{
		"sessionID": "ses_native",
		"status":    map[string]interface{}{"type": "busy"},
		"metadata":  openCodeNativeMetadataProperties("http://127.0.0.1:4111/", 4111),
	})
	if rec.lastState != nil || store.updateCalls != 0 || len(tmuxStub.calls) != 0 || len(tmuxStub.paneIdentityCalls) != 0 {
		t.Fatalf("native lifecycle established identity: state=%+v manifest=%d env=%+v identity=%+v", rec.lastState, store.updateCalls, tmuxStub.calls, tmuxStub.paneIdentityCalls)
	}
}

func TestHookOpenCodeNativeSessionUpdateChecksPaneInsideStateMutation(t *testing.T) {
	r, rec := newTestRunner(t)
	sessionID := "qm-opencode-native-lock-check"
	t.Setenv("TMUX_PANE", "%9")
	store := newManifestStoreStub(sessionID, nil)
	store.manifest.Agents = []state.AgentManifest{{Name: "opencode", Role: "primary", CLI: "opencode", Window: tmux.WindowWorkspace}}
	inMutation := false
	tmuxStub := &tmuxEnvStub{paneIdentityPID: 4111, paneIdentityHook: func() {
		if !inMutation {
			t.Fatal("PaneIdentity ran outside the state mutation")
		}
	}}
	r.Store = store
	r.TmuxClient = tmuxStub
	r.Update = func(id string, mutate func(*state.SessionState) bool) error {
		ss := &state.SessionState{SessionID: id, Version: state.SchemaVersion, Panes: map[string]state.PaneState{}}
		inMutation = true
		changed := mutate(ss)
		inMutation = false
		if changed {
			rec.lastState = ss
		}
		return nil
	}

	openCodeHookEvent(t, r, sessionID, "session.updated", openCodeNativeSessionProperties(
		"ses_native", "questmaster-worker", "http://127.0.0.1:4111/", 4111, 1,
	))
	if rec.lastState == nil || rec.lastState.Panes["primary"].OpenCodeSessionID != "ses_native" {
		t.Fatalf("native update was not accepted: %+v", rec.lastState)
	}
}

func TestHookOpenCodeNativeSessionUpdatePublishesAfterStateMutation(t *testing.T) {
	r, rec := newTestRunner(t)
	sessionID := "qm-opencode-native-publication-order"
	cleanupRuntimeDir(t, sessionID)
	t.Setenv("TMUX_PANE", "%9")
	store := newManifestStoreStub(sessionID, nil)
	store.manifest.Agents = []state.AgentManifest{{Name: "opencode", Role: "primary", CLI: "opencode", Window: tmux.WindowWorkspace}}
	tmuxStub := &tmuxEnvStub{paneIdentityPID: 4111}
	r.Store = store
	r.TmuxClient = tmuxStub
	inMutation := false
	r.UpdateOpenCodeIdentity = func(id string, ev state.StateEvent, mutate func(*state.Manifest, *state.SessionState) bool, publish func() error) (bool, error) {
		manifest := store.manifest
		ss := &state.SessionState{SessionID: id, Version: state.SchemaVersion, Panes: map[string]state.PaneState{}}
		inMutation = true
		accepted := mutate(&manifest, ss)
		inMutation = false
		if len(tmuxStub.calls) != 0 {
			t.Fatalf("tmux publication ran under state mutation: %+v", tmuxStub.calls)
		}
		if _, err := os.Stat(filepath.Join("/tmp", id, "opencode-session-id")); !os.IsNotExist(err) {
			t.Fatalf("runtime publication ran under state mutation: %v", err)
		}
		if !accepted {
			return false, nil
		}
		store.manifest = manifest
		rec.lastState = ss
		rec.events = append(rec.events, ev)
		return true, publish()
	}
	tmuxStub.paneIdentityHook = func() {
		if !inMutation {
			t.Fatal("PaneIdentity ran outside the state mutation")
		}
	}

	openCodeHookEvent(t, r, sessionID, "session.updated", openCodeNativeSessionProperties(
		"ses_native", "questmaster-worker", "http://127.0.0.1:4111/", 4111, 1,
	))
	if got := rec.lastState.Panes["primary"].OpenCodeSessionID; got != "ses_native" {
		t.Fatalf("state identity = %q", got)
	}
	if got := store.manifest.ExtraString("opencode_session_id"); got != "ses_native" {
		t.Fatalf("manifest identity = %q", got)
	}
	if len(tmuxStub.calls) != 1 || tmuxStub.calls[0].value != "ses_native" {
		t.Fatalf("publication did not run after mutation: %+v", tmuxStub.calls)
	}
}

func TestHookOpenCodeNativeSessionUpdateUsesStoreAtomicPath(t *testing.T) {
	root := t.TempDir()
	t.Setenv("QUESTMASTER_STATE_ROOT", root)
	t.Setenv("TMUX_PANE", "%9")
	const sessionID = "qm-opencode-native-store"
	cleanupRuntimeDir(t, sessionID)
	store, err := state.NewStore(root)
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	if err := store.Create(state.Manifest{SessionID: sessionID, Agents: []state.AgentManifest{{
		Name: "opencode", Role: "primary", CLI: "opencode", Window: tmux.WindowWorkspace,
	}}}); err != nil {
		t.Fatalf("create manifest: %v", err)
	}
	tmuxStub := &tmuxEnvStub{paneIdentityPID: 4111}
	r := newHookRunner(store, tmuxStub)
	r.Now = func() time.Time { return time.Date(2026, 8, 12, 1, 2, 3, 0, time.UTC) }
	openCodeHookEvent(t, r, sessionID, "session.updated", openCodeNativeSessionProperties(
		"ses_native", "questmaster-worker", "http://127.0.0.1:4111/", 4111, 1,
	))
	ss, err := state.LoadSessionState(sessionID)
	if err != nil {
		t.Fatalf("load state: %v", err)
	}
	manifest, err := store.Read(sessionID)
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}
	if ss.Panes["primary"].OpenCodeSessionID != "ses_native" || manifest.ExtraString("opencode_session_id") != "ses_native" || manifest.Agents[0].ResumeID != "ses_native" {
		t.Fatalf("state and manifest did not commit together: pane=%+v manifest=%+v", ss.Panes["primary"], manifest)
	}
	if len(tmuxStub.calls) != 1 || tmuxStub.calls[0] != (tmuxEnvCall{session: sessionID, key: "OPENCODE_SESSION_ID", value: "ses_native"}) {
		t.Fatalf("tmux publication = %+v", tmuxStub.calls)
	}
	data, err := os.ReadFile(filepath.Join("/tmp", sessionID, "opencode-session-id"))
	if err != nil || strings.TrimSpace(string(data)) != "ses_native" {
		t.Fatalf("runtime publication = %q, %v", data, err)
	}
}

func TestHookOpenCodeLegacyEventCannotOverrideNativeIdentity(t *testing.T) {
	r, rec := newTestRunner(t)
	sessionID := "qm-opencode-native-reject-legacy"
	t.Setenv("TMUX_PANE", "%9")
	store := newManifestStoreStub(sessionID, nil)
	store.manifest.Agents = []state.AgentManifest{{Name: "opencode", Role: "primary", CLI: "opencode", Window: tmux.WindowWorkspace}}
	tmuxStub := &tmuxEnvStub{paneIdentityPID: 4111}
	r.Store = store
	r.TmuxClient = tmuxStub
	openCodeHookEvent(t, r, sessionID, "session.updated", openCodeNativeSessionProperties(
		"ses_native", "questmaster-worker", "http://127.0.0.1:4111/", 4111, 1,
	))
	writes, manifestUpdates, envCalls := rec.writeCalls, store.updateCalls, len(tmuxStub.calls)
	openCodeHookEvent(t, r, sessionID, "session.status", map[string]interface{}{
		"sessionID": "ses_native", "status": map[string]interface{}{"type": "busy"},
	})
	if rec.writeCalls != writes || store.updateCalls != manifestUpdates || len(tmuxStub.calls) != envCalls {
		t.Fatalf("legacy event changed native identity state=%d/%d manifest=%d/%d env=%d/%d", rec.writeCalls, writes, store.updateCalls, manifestUpdates, len(tmuxStub.calls), envCalls)
	}
}

func TestOpenCodeNativeMetadataRejectsInvalidSequence(t *testing.T) {
	for name, value := range map[string]interface{}{
		"missing":     nil,
		"zero":        float64(0),
		"fraction":    1.5,
		"too large":   float64(1 << 53),
		"string":      "1",
		"json number": json.Number("2"),
	} {
		t.Run(name, func(t *testing.T) {
			metadata := openCodeNativeMetadataProperties("http://127.0.0.1:4111/", 4111)
			questmaster := metadata["questmaster"].(map[string]interface{})
			if value != nil {
				questmaster["session_update_seq"] = value
			}
			_, _, _, _, _, hasSeq, native := openCodeNativeMetadata(openCodeEvent{Properties: map[string]interface{}{"metadata": metadata}})
			if !native || hasSeq {
				t.Fatalf("metadata native=%t hasSeq=%t, want native without sequence", native, hasSeq)
			}
		})
	}
}

func TestHookOpenCodeNativeSessionUpdateRejectsSupersededIdentity(t *testing.T) {
	r, rec := newTestRunner(t)
	sessionID := "qm-opencode-native-resume-gate"
	cleanupRuntimeDir(t, sessionID)
	store := newManifestStoreStub(sessionID, nil)
	store.manifest.Agents = []state.AgentManifest{{Name: "opencode", Role: "primary", CLI: "opencode", Window: tmux.WindowWorkspace}}
	tmuxStub := &tmuxEnvStub{}
	r.Store = store
	r.TmuxClient = tmuxStub
	rec.lastState = &state.SessionState{SessionID: sessionID, Version: state.SchemaVersion, Panes: map[string]state.PaneState{
		"primary": {OpenCodeServerURL: "http://127.0.0.1:1/", OpenCodePID: 1, OpenCodeSessionID: "ses_a", OpenCodeSessionUpdateSeq: 1},
	}}
	r.Update = func(id string, mutate func(*state.SessionState) bool) error {
		pane := rec.lastState.Panes["primary"]
		pane.OpenCodeSessionID = "ses_b"
		pane.OpenCodeServerURL = "http://127.0.0.1:2/"
		pane.OpenCodePID = 2
		pane.OpenCodeSessionUpdateSeq = 2
		rec.lastState.Panes["primary"] = pane
		_ = mutate(rec.lastState)
		return nil
	}

	_, err := updateNativeOpenCodeIdentity(context.Background(), r, io.Discard, sessionID, time.Now(), openCodePatch{
		kind: "session.updated", native: true, sessionID: "ses_a", serverURL: "http://127.0.0.1:1/", serverPID: 1, updateSeq: 1,
		hasURL: true, hasPID: true, hasAgent: true, hasUpdateSeq: true, agent: "questmaster-worker",
	}, state.StateEvent{Action: "session.updated"})
	if err != nil {
		t.Fatalf("update native identity: %v", err)
	}
	if store.updateCalls != 0 || len(tmuxStub.calls) != 0 {
		t.Fatalf("superseded native update captured resume state: manifest=%d env=%+v", store.updateCalls, tmuxStub.calls)
	}
	if _, err := os.Stat(filepath.Join("/tmp", sessionID, "opencode-session-id")); !os.IsNotExist(err) {
		t.Fatalf("superseded native update wrote runtime resume id: %v", err)
	}
}

func openCodeNativeSessionProperties(id, agent, serverURL string, pid int, seq uint64) map[string]interface{} {
	return map[string]interface{}{
		"info":     map[string]interface{}{"id": id, "agent": agent},
		"metadata": openCodeNativeMetadataProperties(serverURL, pid, seq),
	}
}

func openCodeNativeMetadataProperties(serverURL string, pid int, seq ...uint64) map[string]interface{} {
	questmaster := map[string]interface{}{"server_url": serverURL, "pid": pid}
	if len(seq) != 0 {
		questmaster["session_update_seq"] = seq[0]
	}
	return map[string]interface{}{"questmaster": questmaster}
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
	if agent.Name != "opencode" || agent.Role != "primary" || agent.CLI != "opencode" ||
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
		Name: "codex", Role: "primary", CLI: "codex", ResumeID: "codex-thread-1", Window: tmux.WindowWorkspace,
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
	if agent.Name != "opencode" || agent.Role != "primary" || agent.CLI != "opencode" ||
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
