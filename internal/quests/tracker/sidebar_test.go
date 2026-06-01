package tracker

import (
	"testing"
)

func TestActivityDotStopped(t *testing.T) {
	t.Parallel()

	row := SessionRow{Status: "stopped"}
	if got := row.activityDot(); got == "" {
		t.Fatal("expected stopped glyph")
	}
}

func TestActivityDotUsesAgentIdentity(t *testing.T) {
	t.Parallel()

	row := SessionRow{Status: "active", SessionType: "worker", PrimaryAgent: "claude"}
	want := agentIdentityStyle("claude").Render("\U000f06c4")
	if got := row.activityDot(); got != want {
		t.Fatalf("worker activity dot = %q, want %q", got, want)
	}
}

func TestActivityDotSteadyForWorking(t *testing.T) {
	t.Parallel()

	row := SessionRow{Status: "active", State: "working", PrimaryAgent: "claude"}
	if got := row.activityDot(); got == "" {
		t.Fatal("expected working dot")
	}
}
