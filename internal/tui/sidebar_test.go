package tui

import (
	"testing"
)

func TestActivityDotStopped(t *testing.T) {
	t.Parallel()

	row := SessionRow{Status: "stopped"}
	if got := row.activityDot(true); got == "" {
		t.Fatal("expected stopped glyph")
	}
}

func TestActivityDotUsesAgentIdentity(t *testing.T) {
	t.Parallel()

	row := SessionRow{Status: "active", SessionType: "worker", PrimaryAgent: "claude"}
	want := agentIdentityStyle("claude").Render("\U000f06c4")
	if got := row.activityDot(true); got != want {
		t.Fatalf("worker activity dot = %q, want %q", got, want)
	}
}

func TestActivityDotSteadyAcrossBlinkPhasesForWorking(t *testing.T) {
	t.Parallel()

	row := SessionRow{Status: "active", State: "working", PrimaryAgent: "claude"}
	if on, off := row.activityDot(true), row.activityDot(false); on != off {
		t.Fatalf("working dot must be steady; got on=%q off=%q", on, off)
	}
}
