package sessionactivity

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func writeFixtureState(t *testing.T, root, id string, panes map[string]map[string]any, seenAt time.Time) {
	t.Helper()

	dir := filepath.Join(root, id)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}

	doc := map[string]any{
		"session_id": id,
		"version":    1,
		"panes":      panes,
		"seen_at":    seenAt,
	}
	data, err := json.Marshal(doc)
	if err != nil {
		t.Fatalf("marshal fixture: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "state.json"), data, 0o644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
}

func setStateRoot(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	t.Setenv("QUESTMASTER_STATE_ROOT", root)
	t.Setenv("PARTY_STATE_ROOT", root)
	return root
}

func TestEvaluateReadsStateJSON(t *testing.T) {
	root := setStateRoot(t)
	now := time.Date(2026, time.May, 20, 12, 0, 0, 0, time.UTC)
	writeFixtureState(t, root, "party-abc", map[string]map[string]any{
		"primary": {
			"role":       "primary",
			"agent":      "claude",
			"state":      "working",
			"activity":   "Edit foo.go",
			"last_event": now.Add(-2 * time.Second),
			"last_kind":  "PreToolUse",
		},
	}, now)

	results := Evaluate([]Observation{{
		Key:       PrimaryKey("party-abc"),
		SessionID: "party-abc",
		Enabled:   true,
	}})

	got := results[PrimaryKey("party-abc")]
	if got.State != "working" {
		t.Fatalf("state = %q, want working", got.State)
	}
	if got.Activity != "Edit foo.go" {
		t.Fatalf("activity = %q", got.Activity)
	}
	if got.LastKind != "PreToolUse" {
		t.Fatalf("last_kind = %q", got.LastKind)
	}
}

func TestEvaluateMissingStateJSONReturnsUnknown(t *testing.T) {
	setStateRoot(t)

	results := Evaluate([]Observation{{
		Key:       PrimaryKey("party-no-state"),
		SessionID: "party-no-state",
		Enabled:   true,
	}})

	got := results[PrimaryKey("party-no-state")]
	if got.State != "unknown" {
		t.Fatalf("state = %q, want unknown", got.State)
	}
}

// TestEvaluateOldWorkingPreservesState verifies that a working pane
// whose last hook event is well in the past keeps its working state.
// Pure-reasoning phases can run for minutes with no hook activity, and
// we must not lie about the state just because we haven't heard from
// the agent recently.
func TestEvaluateOldWorkingPreservesState(t *testing.T) {
	root := setStateRoot(t)
	now := time.Date(2026, time.May, 20, 12, 0, 0, 0, time.UTC)
	lastEvent := now.Add(-90 * time.Second)
	writeFixtureState(t, root, "party-old-working", map[string]map[string]any{
		"primary": {
			"role":       "primary",
			"agent":      "codex",
			"state":      "working",
			"activity":   "Bash: long test",
			"last_event": lastEvent,
			"last_kind":  "PreToolUse",
		},
	}, now)

	results := Evaluate([]Observation{{
		Key:       PrimaryKey("party-old-working"),
		SessionID: "party-old-working",
		Enabled:   true,
	}})

	got := results[PrimaryKey("party-old-working")]
	if got.State != "working" {
		t.Fatalf("old working pane → state = %q, want working", got.State)
	}
	if got.Activity != "Bash: long test" {
		t.Fatalf("Activity should be preserved, got %q", got.Activity)
	}
	if !got.WorkingSince.Equal(lastEvent) {
		t.Fatalf("WorkingSince = %v, want last_event %v for legacy working pane", got.WorkingSince, lastEvent)
	}
}

func TestEvaluateOldIdleStaysIdle(t *testing.T) {
	root := setStateRoot(t)
	now := time.Date(2026, time.May, 20, 12, 0, 0, 0, time.UTC)
	writeFixtureState(t, root, "party-idle", map[string]map[string]any{
		"primary": {
			"role":          "primary",
			"agent":         "claude",
			"state":         "idle",
			"last_event":    now.Add(-10 * time.Minute),
			"working_since": now.Add(-20 * time.Minute),
		},
	}, now)

	got := Evaluate([]Observation{{
		Key:       PrimaryKey("party-idle"),
		SessionID: "party-idle",
		Enabled:   true,
	}})[PrimaryKey("party-idle")]

	if got.State != "idle" {
		t.Fatalf("idle pane should keep state; got %q", got.State)
	}
	if !got.WorkingSince.IsZero() {
		t.Fatalf("idle pane WorkingSince = %v, want zero", got.WorkingSince)
	}
}

func TestEvaluateDisabledReturnsStopped(t *testing.T) {
	setStateRoot(t)

	got := Evaluate([]Observation{{
		Key:       PrimaryKey("party-disabled"),
		SessionID: "party-disabled",
		Enabled:   false,
	}})[PrimaryKey("party-disabled")]

	if got.State != "stopped" {
		t.Fatalf("disabled observation → state = %q, want stopped", got.State)
	}
}

func TestLabel(t *testing.T) {
	t.Parallel()

	tests := map[string]struct {
		state string
		alive bool
		want  string
	}{
		"stopped state": {
			state: "stopped",
			alive: true,
			want:  "stopped",
		},
		"unknown live falls back to active": {
			state: "unknown",
			alive: true,
			want:  "active",
		},
		"named state": {
			state: "working",
			alive: true,
			want:  "working",
		},
		"empty live falls back to active": {
			alive: true,
			want:  "active",
		},
		"empty dead falls back to stopped": {
			want: "stopped",
		},
	}

	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			if got := Label(tc.state, tc.alive); got != tc.want {
				t.Fatalf("Label(%q, %v) = %q, want %q", tc.state, tc.alive, got, tc.want)
			}
		})
	}
}

// TestEvaluateRoundTripsWorkingSince verifies the renderer sees the
// PaneState.WorkingSince timestamp the hook recorded, so it can compute
// the working-duration suffix.
func TestEvaluateRoundTripsWorkingSince(t *testing.T) {
	root := setStateRoot(t)
	now := time.Date(2026, time.May, 20, 12, 0, 0, 0, time.UTC)
	workingSince := now.Add(-30 * time.Second)
	writeFixtureState(t, root, "party-ws", map[string]map[string]any{
		"primary": {
			"role":          "primary",
			"agent":         "claude",
			"state":         "working",
			"activity":      "Edit foo.go",
			"last_event":    now,
			"last_kind":     "PreToolUse",
			"working_since": workingSince,
		},
	}, now)

	got := Evaluate([]Observation{{
		Key:       PrimaryKey("party-ws"),
		SessionID: "party-ws",
		Enabled:   true,
	}})[PrimaryKey("party-ws")]

	if !got.WorkingSince.Equal(workingSince) {
		t.Fatalf("WorkingSince = %v, want %v", got.WorkingSince, workingSince)
	}
}

// TestEvaluateNormalizesLegacyStartingActivity verifies that state.json
// files written by older binaries (where the SessionStart activity was
// "starting…") render as "started" so the snippet word is consistent
// with the rest of the SessionStart flow regardless of which binary
// wrote the file.
func TestEvaluateNormalizesLegacyStartingActivity(t *testing.T) {
	root := setStateRoot(t)
	now := time.Date(2026, time.May, 20, 12, 0, 0, 0, time.UTC)
	writeFixtureState(t, root, "party-legacy-start", map[string]map[string]any{
		"primary": {
			"role":       "primary",
			"agent":      "claude",
			"state":      "starting",
			"activity":   "starting…",
			"last_event": now.Add(-2 * time.Second),
			"last_kind":  "SessionStart",
		},
	}, now)

	got := Evaluate([]Observation{{
		Key:       PrimaryKey("party-legacy-start"),
		SessionID: "party-legacy-start",
		Enabled:   true,
	}})[PrimaryKey("party-legacy-start")]

	if got.State != "starting" {
		t.Fatalf("state = %q, want starting", got.State)
	}
	if got.Activity != "started" {
		t.Fatalf("activity = %q, want %q (legacy \"starting…\" must be normalized)", got.Activity, "started")
	}
}
