//go:build linux || darwin

package cmd

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/anthropics/ai-party/tools/party-cli/internal/state"
	"github.com/anthropics/ai-party/tools/party-cli/internal/tmux"
)

// writeSessionStateFixture writes a state.json fixture into the per-test
// PARTY_STATE_ROOT for the given session.
func writeSessionStateFixture(t *testing.T, sessionID, paneState, activity, lastKind string, lastEvent time.Time) {
	t.Helper()
	root := os.Getenv("PARTY_STATE_ROOT")
	if root == "" {
		t.Fatalf("PARTY_STATE_ROOT must be set by the test")
	}
	dir := filepath.Join(root, sessionID)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("mkdir state dir: %v", err)
	}
	doc := map[string]any{
		"session_id": sessionID,
		"version":    1,
		"seen_at":    time.Now().UTC(),
		"panes": map[string]any{
			"primary": map[string]any{
				"role":       "primary",
				"agent":      "claude",
				"state":      paneState,
				"activity":   activity,
				"last_event": lastEvent,
				"last_kind":  lastKind,
			},
		},
	}
	data, err := json.Marshal(doc)
	if err != nil {
		t.Fatalf("marshal state.json: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "state.json"), data, 0o644); err != nil {
		t.Fatalf("write state.json: %v", err)
	}
}

func TestSessionsJSON_ActiveWhenStateIsWorking(t *testing.T) {
	t.Setenv("PARTY_STATE_ROOT", t.TempDir())

	store := setupStore(t)
	if err := store.Create(state.Manifest{
		PartyID: "party-active",
		Title:   "active session",
		Cwd:     "/tmp/active",
		Agents:  []state.AgentManifest{{Name: "codex", Role: "primary"}},
	}); err != nil {
		t.Fatalf("create manifest: %v", err)
	}

	writeSessionStateFixture(t, "party-active", "working", "Edit: foo.go", "PreToolUse", time.Now())

	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		switch args[0] {
		case "list-sessions":
			return "party-active", nil
		case "list-panes":
			return "party-active\t1 0 primary", nil
		case "capture-pane":
			t.Fatalf("Phase 2 tracker should not call capture-pane")
		}
		return "", &tmux.ExitError{Code: 1}
	}}

	rows := runSessionsJSON(t, store, runner)
	if len(rows) != 1 {
		t.Fatalf("rows: got %d, want 1", len(rows))
	}
	if !rows[0].Active {
		t.Fatal("expected working state to surface as active=true")
	}
	if rows[0].LastChangeMS == 0 {
		t.Fatal("last_change_ms should be populated for an active session")
	}
}

func TestSessionsJSON_InactiveWhenStateIsIdle(t *testing.T) {
	t.Setenv("PARTY_STATE_ROOT", t.TempDir())

	store := setupStore(t)
	if err := store.Create(state.Manifest{
		PartyID: "party-quiet",
		Agents:  []state.AgentManifest{{Name: "codex", Role: "primary"}},
	}); err != nil {
		t.Fatalf("create manifest: %v", err)
	}

	writeSessionStateFixture(t, "party-quiet", "idle", "", "", time.Now().Add(-time.Minute))

	rows := runSessionsJSON(t, store, sessionsRunner("party-quiet"))
	if len(rows) != 1 {
		t.Fatalf("rows: got %d, want 1", len(rows))
	}
	if rows[0].Active {
		t.Fatal("idle state must not be reported active")
	}
}

func TestSessionsJSON_UsesPiHookStateWorkingSignal(t *testing.T) {
	t.Setenv("PARTY_STATE_ROOT", t.TempDir())

	sessionID := "party-pi-sessions-state"
	store := setupStore(t)
	if err := store.Create(state.Manifest{
		PartyID: sessionID,
		Title:   "pi busy",
		Agents:  []state.AgentManifest{{Name: "pi", Role: "primary"}},
	}); err != nil {
		t.Fatalf("create manifest: %v", err)
	}
	writeSessionStateFixture(t, sessionID, "working", "Thinking...", "message_update", time.Now())

	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		switch args[0] {
		case "list-sessions":
			return sessionID, nil
		case "list-panes":
			return sessionID + "\t1 0 primary", nil
		case "capture-pane":
			t.Fatalf("Phase 3 tracker should not call capture-pane")
		}
		return "", &tmux.ExitError{Code: 1}
	}}

	rows := runSessionsJSON(t, store, runner)
	if len(rows) != 1 {
		t.Fatalf("rows: got %d, want 1", len(rows))
	}
	if !rows[0].Active {
		t.Fatal("expected Pi working state to mark session active")
	}
	if rows[0].LastChangeMS == 0 {
		t.Fatal("last_change_ms should be populated for working state")
	}
}

func TestSessionsJSON_UsesTrackerOrder(t *testing.T) {
	t.Setenv("PARTY_STATE_ROOT", t.TempDir())

	store := setupStore(t)
	for _, manifest := range []state.Manifest{
		{
			PartyID:     "party-standalone",
			Title:       "standalone",
			Cwd:         "/tmp/standalone",
			CreatedAt:   "2026-04-21T00:00:01Z",
			Agents:      []state.AgentManifest{{Name: "claude", Role: "primary"}},
			SessionType: "",
		},
		{
			PartyID:     "party-master",
			Title:       "master",
			Cwd:         "/tmp/master",
			CreatedAt:   "2026-04-21T00:00:03Z",
			SessionType: "master",
			Workers:     []string{"party-worker"},
			Agents:      []state.AgentManifest{{Name: "codex", Role: "primary"}},
		},
		{
			PartyID:   "party-worker",
			Title:     "worker",
			Cwd:       "/tmp/worker",
			CreatedAt: "2026-04-21T00:00:02Z",
			Agents:    []state.AgentManifest{{Name: "claude", Role: "primary"}},
			Extra: map[string]json.RawMessage{
				"parent_session": json.RawMessage(`"party-master"`),
			},
		},
		{
			PartyID:   "party-orphan",
			Title:     "orphan",
			Cwd:       "/tmp/orphan",
			CreatedAt: "2026-04-21T00:00:00Z",
			Agents:    []state.AgentManifest{{Name: "codex", Role: "primary"}},
			Extra: map[string]json.RawMessage{
				"parent_session": json.RawMessage(`"party-gone"`),
			},
		},
	} {
		if err := store.Create(manifest); err != nil {
			t.Fatalf("create manifest %s: %v", manifest.PartyID, err)
		}
	}

	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		switch args[0] {
		case "list-sessions":
			return "party-orphan\nparty-standalone\nparty-worker\nparty-master", nil
		case "list-panes":
			return strings.Join([]string{
				"party-master\t1 0 primary",
				"party-worker\t1 0 primary",
				"party-standalone\t1 0 primary",
				"party-orphan\t1 0 primary",
			}, "\n"), nil
		case "capture-pane":
			t.Fatalf("Phase 2 tracker should not call capture-pane")
		}
		return "", &tmux.ExitError{Code: 1}
	}}

	rows := runSessionsJSON(t, store, runner)
	if len(rows) != 4 {
		t.Fatalf("rows: got %d, want 4", len(rows))
	}

	gotOrder := []string{rows[0].PartyID, rows[1].PartyID, rows[2].PartyID, rows[3].PartyID}
	wantOrder := []string{"party-master", "party-worker", "party-standalone", "party-orphan"}
	if strings.Join(gotOrder, ",") != strings.Join(wantOrder, ",") {
		t.Fatalf("order: got %v, want %v", gotOrder, wantOrder)
	}

	if rows[0].PrimaryTool != "codex" {
		t.Fatalf("master primary_tool: got %q, want %q", rows[0].PrimaryTool, "codex")
	}
	if rows[1].SessionType != "worker" {
		t.Fatalf("worker session_type: got %q, want %q", rows[1].SessionType, "worker")
	}
	if rows[1].ParentSession != "party-master" {
		t.Fatalf("worker parent_session: got %q, want %q", rows[1].ParentSession, "party-master")
	}
	if rows[2].SessionType != "standalone" {
		t.Fatalf("standalone session_type: got %q, want %q", rows[2].SessionType, "standalone")
	}
}

func TestSessionsJSON_GracefullyHandlesNoStateJSON(t *testing.T) {
	t.Setenv("PARTY_STATE_ROOT", t.TempDir())

	store := setupStore(t)
	rows := runSessionsJSON(t, store, sessionsRunner())
	if len(rows) != 0 {
		t.Fatalf("rows: got %d, want 0", len(rows))
	}
}

func runSessionsJSON(t *testing.T, store *state.Store, runner tmux.Runner) []sessionsJSONRow {
	t.Helper()

	out := runCmd(t, store, runner, "sessions")
	var rows []sessionsJSONRow
	if err := json.Unmarshal([]byte(out), &rows); err != nil {
		t.Fatalf("unmarshal sessions json: %v\noutput: %s", err, out)
	}
	return rows
}
