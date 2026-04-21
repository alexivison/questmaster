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

	"github.com/anthropics/ai-party/tools/party-cli/internal/sessionactivity"
	"github.com/anthropics/ai-party/tools/party-cli/internal/state"
	"github.com/anthropics/ai-party/tools/party-cli/internal/tmux"
)

func TestSessionsJSON_FlipsActiveWhenPrimarySnippetChanges(t *testing.T) {
	t.Parallel()

	store := setupStore(t)
	if err := store.Create(state.Manifest{
		PartyID: "party-active",
		Title:   "active session",
		Cwd:     "/tmp/active",
		Agents:  []state.AgentManifest{{Name: "codex", Role: "primary"}},
	}); err != nil {
		t.Fatalf("create manifest: %v", err)
	}

	snippet := "⏺ still working"
	writeActivityState(t, filepath.Join(store.Root(), activityStateFilename), sessionactivity.State{
		Entries: map[string]sessionactivity.Entry{
			sessionactivity.PrimaryKey("party-active"): {
				SnippetHash:  sessionactivity.HashSnippet(snippet),
				LastChangeAt: time.Now().Add(-5 * time.Second),
			},
		},
	})

	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		switch args[0] {
		case "list-sessions":
			return "party-active", nil
		case "list-panes":
			return "party-active\t1 0 primary", nil
		case "capture-pane":
			return snippet, nil
		default:
			return "", &tmux.ExitError{Code: 1}
		}
	}}

	rows := runSessionsJSON(t, store, runner)
	if len(rows) != 1 {
		t.Fatalf("rows: got %d, want 1", len(rows))
	}
	if rows[0].Active {
		t.Fatalf("active before snippet change: got true, want false")
	}

	snippet = "⏺ moved on"
	rows = runSessionsJSON(t, store, runner)
	if len(rows) != 1 {
		t.Fatalf("rows after change: got %d, want 1", len(rows))
	}
	if !rows[0].Active {
		t.Fatal("active after snippet change: got false, want true")
	}
	if rows[0].LastChangeMS == 0 {
		t.Fatal("last_change_ms should be populated when a session is active")
	}
}

func TestSessionsJSON_UsesTrackerOrder(t *testing.T) {
	t.Parallel()

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
			// Deliberately not tracker order; command must normalize.
			return "party-orphan\nparty-standalone\nparty-worker\nparty-master", nil
		case "list-panes":
			return strings.Join([]string{
				"party-master\t1 0 primary",
				"party-worker\t1 0 primary",
				"party-standalone\t1 0 primary",
				"party-orphan\t1 0 primary",
			}, "\n"), nil
		case "capture-pane":
			return "", nil
		default:
			return "", &tmux.ExitError{Code: 1}
		}
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

func TestSessionsJSON_GracefullyHandlesNoTmuxAndStaleStateFile(t *testing.T) {
	t.Parallel()

	store := setupStore(t)
	activityPath := filepath.Join(store.Root(), activityStateFilename)
	writeActivityStateBytes(t, activityPath, []byte("{not-json"))

	rows := runSessionsJSON(t, store, sessionsRunner())
	if len(rows) != 0 {
		t.Fatalf("rows: got %d, want 0", len(rows))
	}
	data, err := os.ReadFile(activityPath)
	if err != nil {
		t.Fatalf("read activity state after malformed input: %v", err)
	}
	if string(data) != "{not-json" {
		t.Fatalf("malformed activity state should be preserved, got %q", string(data))
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

func writeActivityState(t *testing.T, path string, snapshot sessionactivity.State) {
	t.Helper()

	data, err := json.Marshal(snapshot)
	if err != nil {
		t.Fatalf("marshal activity state: %v", err)
	}
	writeActivityStateBytes(t, path, data)
}

func writeActivityStateBytes(t *testing.T, path string, data []byte) {
	t.Helper()

	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatalf("write activity state: %v", err)
	}
}
