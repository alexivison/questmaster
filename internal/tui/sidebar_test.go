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

func TestIsGeneratingWatchesPrimarySnippetDelta(t *testing.T) {
	t.Parallel()

	cases := []struct {
		name string
		row  SessionRow
		want bool
	}{
		{"primary snippet changed", SessionRow{Status: "active", PrimaryActive: true}, true},
		{"stopped session ignores activity", SessionRow{Status: "stopped", PrimaryActive: true}, false},
		{"unchanged snippet", SessionRow{Status: "active"}, false},
	}
	for _, tc := range cases {
		if got := tc.row.isGenerating(); got != tc.want {
			t.Errorf("%s: isGenerating() = %v, want %v", tc.name, got, tc.want)
		}
	}
}
