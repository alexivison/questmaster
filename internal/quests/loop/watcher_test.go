package loop

import (
	"context"
	"encoding/json"
	"os"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/state"
)

func TestStateWatcherEmitsOneDonePerIncreasingEdge(t *testing.T) {
	root := t.TempDir()
	sessionID := "qm-watch"
	t.Setenv(state.StateRootEnv, root)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	events := NewStateWatcher(root, sessionID, time.Millisecond).Events(ctx)

	assertNoEvent(t, events)
	writePaneState(t, sessionID, "working", 1, ts(1))
	assertNoEvent(t, events)

	writePaneState(t, sessionID, "done", 2, ts(2))
	assertEvent(t, events, EventDone)
	writePaneState(t, sessionID, "done", 2, ts(2))
	assertNoEvent(t, events)

	writePaneState(t, sessionID, "working", 3, ts(3))
	assertNoEvent(t, events)
	writePaneState(t, sessionID, "done", 4, ts(4))
	assertEvent(t, events, EventDone)
	assertNoEvent(t, events)
}

func TestStateWatcherEmitsBlocked(t *testing.T) {
	root := t.TempDir()
	sessionID := "qm-block"
	t.Setenv(state.StateRootEnv, root)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	events := NewStateWatcher(root, sessionID, time.Millisecond).Events(ctx)

	writePaneState(t, sessionID, "blocked", 10, ts(10))
	assertEvent(t, events, EventBlocked)
	writePaneState(t, sessionID, "blocked", 10, ts(10))
	assertNoEvent(t, events)
}

func TestStateWatcherIgnoresColdDoneAndForeignState(t *testing.T) {
	root := t.TempDir()
	sessionID := "qm-cold"
	t.Setenv(state.StateRootEnv, root)
	writePaneState(t, sessionID, "done", 5, ts(5))

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	events := NewStateWatcher(root, sessionID, time.Millisecond).Events(ctx)
	assertNoEvent(t, events)

	writeForeignState(t, root, sessionID, "done", 6, ts(6))
	assertNoEvent(t, events)

	writePaneState(t, sessionID, "done", 7, ts(7))
	assertEvent(t, events, EventDone)
}

func writePaneState(t *testing.T, sessionID, paneState string, seq int64, lastEvent time.Time) {
	t.Helper()
	if err := state.UpdateSessionState(sessionID, func(ss *state.SessionState) bool {
		ss.Version = state.SchemaVersion
		ss.Panes["primary"] = state.PaneState{
			Role:      "primary",
			Agent:     "codex",
			State:     paneState,
			Seq:       seq,
			LastEvent: lastEvent,
			LastKind:  "test",
		}
		return true
	}); err != nil {
		t.Fatalf("write state: %v", err)
	}
}

func writeForeignState(t *testing.T, root, sessionID, paneState string, seq int64, lastEvent time.Time) {
	t.Helper()
	ss := state.SessionState{
		SessionID: sessionID,
		Version:   state.SchemaVersion + 1,
		Panes: map[string]state.PaneState{
			"primary": {
				Role:      "primary",
				Agent:     "codex",
				State:     paneState,
				Seq:       seq,
				LastEvent: lastEvent,
			},
		},
	}
	dir := state.SessionStateDir(root, sessionID)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("mkdir state dir: %v", err)
	}
	data, err := json.Marshal(ss)
	if err != nil {
		t.Fatalf("marshal foreign state: %v", err)
	}
	if err := os.WriteFile(state.SessionStatePath(root, sessionID), append(data, '\n'), 0o644); err != nil {
		t.Fatalf("write foreign state: %v", err)
	}
}

func assertEvent(t *testing.T, events <-chan Event, want EventKind) {
	t.Helper()
	select {
	case got := <-events:
		if got.Kind != want {
			t.Fatalf("event kind = %q, want %q", got.Kind, want)
		}
	case <-time.After(time.Second):
		t.Fatalf("timed out waiting for %q", want)
	}
}

func assertNoEvent(t *testing.T, events <-chan Event) {
	t.Helper()
	select {
	case got := <-events:
		t.Fatalf("unexpected event: %q", got.Kind)
	case <-time.After(25 * time.Millisecond):
	}
}

func ts(n int64) time.Time {
	return time.Unix(n, 0).UTC()
}
