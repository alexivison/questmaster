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

func TestEvaluateActiveOverrideBusyForcesWorking(t *testing.T) {
	setStateRoot(t)
	now := time.Date(2026, time.May, 20, 12, 0, 0, 0, time.UTC)
	busy := true

	got := Evaluate(now, []Observation{{
		Key:            PrimaryKey("party-pi"),
		SessionID:      "party-pi",
		Enabled:        true,
		ActiveOverride: &busy,
	}})[PrimaryKey("party-pi")]

	if got.State != "working" {
		t.Fatalf("Pi busy override → state = %q, want working", got.State)
	}
}

func TestEvaluateActiveOverrideIdleDowngradesWorking(t *testing.T) {
	root := setStateRoot(t)
	now := time.Date(2026, time.May, 20, 12, 0, 0, 0, time.UTC)
	writeFixtureState(t, root, "party-pi-quiet", map[string]map[string]any{
		"primary": {
			"role":       "primary",
			"agent":      "pi",
			"state":      "working",
			"last_event": now,
		},
	}, now)
	quiet := false

	got := Evaluate(now, []Observation{{
		Key:            PrimaryKey("party-pi-quiet"),
		SessionID:      "party-pi-quiet",
		Enabled:        true,
		ActiveOverride: &quiet,
	}})[PrimaryKey("party-pi-quiet")]

	if got.State != "idle" {
		t.Fatalf("Pi quiet override over working state → got %q, want idle", got.State)
	}
}
