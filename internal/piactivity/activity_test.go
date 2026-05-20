package piactivity

import (
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"github.com/anthropics/ai-party/tools/party-cli/internal/state"
)

func setStateRoot(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	t.Setenv("PARTY_STATE_ROOT", root)
	return root
}

func writeState(t *testing.T, sessionID string, pane state.PaneState, seenAt time.Time) {
	t.Helper()
	if pane.Role == "" {
		pane.Role = "primary"
	}
	if pane.Agent == "" {
		pane.Agent = "pi"
	}
	if pane.LastEvent.IsZero() {
		pane.LastEvent = seenAt
	}
	if pane.Seq == 0 && !pane.LastEvent.IsZero() {
		pane.Seq = pane.LastEvent.UnixNano()
	}
	if err := state.SaveSessionState(sessionID, &state.SessionState{
		SessionID: sessionID,
		Version:   state.SchemaVersion,
		SeenAt:    seenAt,
		Panes: map[string]state.PaneState{
			"primary": pane,
		},
	}); err != nil {
		t.Fatalf("save state: %v", err)
	}
}

func TestReadFreshState(t *testing.T) {
	setStateRoot(t)
	now := time.Date(2026, time.May, 7, 12, 0, 0, 0, time.UTC)
	sessionID := "party-piactivity-fresh"
	resumeID := "019dee69-5623-75c9-9317-04bf7f94e92b"
	writeState(t, sessionID, state.PaneState{
		State:       "working",
		Activity:    " running tests ",
		Recent:      []string{"", " read file ", "running tests"},
		LastEvent:   now.Add(-time.Second),
		SessionFile: filepath.Join("/Users/aleksi/.pi/agent/sessions/project", "2026-05-03T15-16-13-988Z_"+resumeID+".jsonl"),
	}, now.Add(-time.Second))

	got, ok := Read(sessionID, now)
	if !ok {
		t.Fatal("expected fresh state")
	}
	if !got.Busy || got.Phase != "working" || got.Snippet != "running tests" {
		t.Fatalf("unexpected snapshot: %+v", got)
	}
	if want := []string{"read file", "running tests"}; !reflect.DeepEqual(got.Recent, want) {
		t.Fatalf("recent = %#v, want %#v", got.Recent, want)
	}
	if got.ResumeID != resumeID {
		t.Fatalf("ResumeID = %q, want %q", got.ResumeID, resumeID)
	}
}

func TestReadLatestAndReadResumeIDUsePiCarryThroughFields(t *testing.T) {
	setStateRoot(t)
	now := time.Date(2026, time.May, 7, 12, 0, 0, 0, time.UTC)
	sessionID := "party-piactivity-carry"
	resumeID := "019dee69-5623-75c9-9317-04bf7f94e92b"
	writeState(t, sessionID, state.PaneState{
		State:       "done",
		Activity:    "Said: shipped it",
		Recent:      []string{"first", " second "},
		LastEvent:   now.Add(-time.Hour),
		SessionFile: "/tmp/ignored.jsonl",
		PiSessionID: " " + resumeID + " ",
	}, now.Add(-time.Hour))

	latest, ok := ReadLatest(sessionID)
	if !ok {
		t.Fatal("expected latest state")
	}
	if latest.Busy {
		t.Fatalf("done state should not be busy: %+v", latest)
	}
	if latest.Snippet != "Said: shipped it" {
		t.Fatalf("Snippet = %q", latest.Snippet)
	}
	if want := []string{"first", "second"}; !reflect.DeepEqual(latest.Recent, want) {
		t.Fatalf("Recent = %#v, want %#v", latest.Recent, want)
	}
	if latest.ResumeID != resumeID {
		t.Fatalf("latest ResumeID = %q, want %q", latest.ResumeID, resumeID)
	}
	if got, ok := ReadResumeID(sessionID); !ok || got != resumeID {
		t.Fatalf("ReadResumeID = %q ok=%v, want %q true", got, ok, resumeID)
	}
}

func TestResumeIDFromSessionFile(t *testing.T) {
	t.Parallel()

	validID := "019dee69-5623-75c9-9317-04bf7f94e92b"
	validFile := "2026-05-03T15-16-13-988Z_" + validID + ".jsonl"
	tests := map[string]struct {
		in   string
		want string
	}{
		"absolute path": {in: filepath.Join("/Users/aleksi/.pi/agent/sessions/project", validFile), want: validID},
		"basename":      {in: validFile, want: validID},
		"no timestamp":  {in: validID + ".jsonl", want: ""},
		"bad extension": {in: "2026-05-03T15-16-13-988Z_" + validID + ".txt", want: ""},
		"glob chars":    {in: "2026-05-03T15-16-13-988Z_019dee69-5623-75c9-9317-04bf7f94e92*.jsonl", want: ""},
		"not uuid":      {in: "2026-05-03T15-16-13-988Z_not-a-real-uuid.jsonl", want: ""},
	}

	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			if got := ResumeIDFromSessionFile(tc.in); got != tc.want {
				t.Fatalf("ResumeIDFromSessionFile(%q) = %q, want %q", tc.in, got, tc.want)
			}
		})
	}
}

func TestReadRejectsStaleAndMismatchedState(t *testing.T) {
	setStateRoot(t)
	now := time.Date(2026, time.May, 7, 12, 0, 0, 0, time.UTC)

	staleID := "party-piactivity-stale"
	writeState(t, staleID, state.PaneState{
		State:     "working",
		Activity:  "last useful update",
		LastEvent: now.Add(-MaxAge - time.Second),
	}, now.Add(-MaxAge-time.Second))
	if _, ok := Read(staleID, now); ok {
		t.Fatal("expected stale state to be rejected")
	}
	if latest, ok := ReadLatest(staleID); !ok || !latest.Busy {
		t.Fatalf("expected stale state to remain available as latest snapshot, got %+v ok=%v", latest, ok)
	}

	mismatchID := "party-piactivity-mismatch"
	writeState(t, mismatchID, state.PaneState{
		Agent:     "claude",
		State:     "working",
		LastEvent: now,
	}, now)
	if _, ok := Read(mismatchID, now); ok {
		t.Fatal("expected non-Pi pane state to be rejected")
	}
}

func TestPathRejectsInvalidPartyID(t *testing.T) {
	setStateRoot(t)
	if got := Path("../../escape"); got != "" {
		t.Fatalf("Path accepted invalid id: %q", got)
	}
}
