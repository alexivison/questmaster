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

func TestActivityDotWorkerUsesWorkerRoleStyle(t *testing.T) {
	t.Parallel()

	row := SessionRow{Status: "active", SessionType: "worker"}
	if got, want := row.activityDot(true), workerGlyphStyle.Render("●"); got != want {
		t.Fatalf("worker activity dot = %q, want %q", got, want)
	}
}

func TestActivityDotWorkingDimsWhenBlinkOff(t *testing.T) {
	t.Parallel()

	row := SessionRow{Status: "active", State: "working"}
	if got, want := row.activityDot(false), dimActivityStyle.Render("●"); got != want {
		t.Fatalf("working dot blink-off = %q, want %q", got, want)
	}
}
