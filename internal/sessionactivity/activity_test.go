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

	results := Evaluate(now, []Observation{{
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
	if got.Stale {
		t.Fatal("expected fresh event to not be stale")
	}
}

func TestEvaluateMissingStateJSONReturnsUnknown(t *testing.T) {
	setStateRoot(t)
	now := time.Date(2026, time.May, 20, 12, 0, 0, 0, time.UTC)

	results := Evaluate(now, []Observation{{
		Key:       PrimaryKey("party-no-state"),
		SessionID: "party-no-state",
		Enabled:   true,
	}})

	got := results[PrimaryKey("party-no-state")]
	if got.State != "unknown" {
		t.Fatalf("state = %q, want unknown", got.State)
	}
}

func TestEvaluateStaleWorkingDowngradesToUnknown(t *testing.T) {
	root := setStateRoot(t)
	now := time.Date(2026, time.May, 20, 12, 0, 0, 0, time.UTC)
	writeFixtureState(t, root, "party-stale", map[string]map[string]any{
		"primary": {
			"role":       "primary",
			"agent":      "codex",
			"state":      "working",
			"activity":   "Bash: long test",
			"last_event": now.Add(-90 * time.Second),
			"last_kind":  "PreToolUse",
		},
	}, now)

	results := Evaluate(now, []Observation{{
		Key:       PrimaryKey("party-stale"),
		SessionID: "party-stale",
		Enabled:   true,
	}})

	got := results[PrimaryKey("party-stale")]
	if got.State != "unknown" {
		t.Fatalf("stale working → state = %q, want unknown", got.State)
	}
	if !got.Stale {
		t.Fatal("expected stale=true")
	}
	if got.Activity != "Bash: long test" {
		t.Fatalf("stale Activity should be preserved, got %q", got.Activity)
	}
}

// TestEvaluateStaleWorkingWithToolStaysWorking guards the
// AskUserQuestion-cancel scenario: PreToolUse fires (state=working,
// tool=AskUserQuestion), the user takes >StaleThreshold to decide, no
// further hook events fire. The renderer must NOT downgrade to
// "unknown" while a tool call is genuinely in progress — the agent is
// waiting on the tool, not stuck.
func TestEvaluateStaleWorkingWithToolStaysWorking(t *testing.T) {
	root := setStateRoot(t)
	now := time.Date(2026, time.May, 20, 12, 0, 0, 0, time.UTC)
	writeFixtureState(t, root, "party-askuser", map[string]map[string]any{
		"primary": {
			"role":       "primary",
			"agent":      "claude",
			"state":      "working",
			"activity":   "AskUserQuestion",
			"tool":       "AskUserQuestion",
			"last_event": now.Add(-90 * time.Second),
			"last_kind":  "PreToolUse",
		},
	}, now)

	got := Evaluate(now, []Observation{{
		Key:       PrimaryKey("party-askuser"),
		SessionID: "party-askuser",
		Enabled:   true,
	}})[PrimaryKey("party-askuser")]

	if got.State != "working" {
		t.Fatalf("stale working with in-progress tool → state = %q, want working", got.State)
	}
	if !got.Stale {
		t.Fatal("expected stale=true (>StaleThreshold)")
	}
}

func TestEvaluateStaleIdleStaysIdle(t *testing.T) {
	root := setStateRoot(t)
	now := time.Date(2026, time.May, 20, 12, 0, 0, 0, time.UTC)
	writeFixtureState(t, root, "party-idle", map[string]map[string]any{
		"primary": {
			"role":       "primary",
			"agent":      "claude",
			"state":      "idle",
			"last_event": now.Add(-10 * time.Minute),
		},
	}, now)

	got := Evaluate(now, []Observation{{
		Key:       PrimaryKey("party-idle"),
		SessionID: "party-idle",
		Enabled:   true,
	}})[PrimaryKey("party-idle")]

	if got.State != "idle" {
		t.Fatalf("idle pane should not be downgraded; got %q", got.State)
	}
	if got.Stale {
		t.Fatal("idle pane should not be flagged stale")
	}
}

func TestEvaluateDisabledReturnsStopped(t *testing.T) {
	setStateRoot(t)
	now := time.Date(2026, time.May, 20, 12, 0, 0, 0, time.UTC)

	got := Evaluate(now, []Observation{{
		Key:       PrimaryKey("party-disabled"),
		SessionID: "party-disabled",
		Enabled:   false,
	}})[PrimaryKey("party-disabled")]

	if got.State != "stopped" {
		t.Fatalf("disabled observation → state = %q, want stopped", got.State)
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

	got := Evaluate(now, []Observation{{
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
