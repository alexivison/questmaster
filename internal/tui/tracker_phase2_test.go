//go:build linux || darwin

package tui

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/charmbracelet/lipgloss"
	"github.com/muesli/termenv"

	"github.com/anthropics/ai-party/tools/party-cli/internal/state"
)

// writeStatePhase2Fixture writes a state.json fixture under
// $PARTY_STATE_ROOT/<id>/state.json so the tracker model picks it up
// when applySnapshot drives sessionactivity.Evaluate.
func writeStatePhase2Fixture(t *testing.T, id, paneState, activity, lastKind string, lastEvent time.Time) {
	t.Helper()
	root := os.Getenv("PARTY_STATE_ROOT")
	if root == "" {
		t.Fatalf("PARTY_STATE_ROOT must be set")
	}
	dir := filepath.Join(root, id)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	doc := map[string]any{
		"session_id": id,
		"version":    1,
		"seen_at":    time.Now().UTC(),
		"panes": map[string]any{
			"primary": map[string]any{
				"role":       "primary",
				"agent":      "claude",
				"state":      paneState,
				"activity":   activity,
				"last_event": lastEvent,
				"last_kind":  lastKind,
			},
		},
	}
	data, err := json.Marshal(doc)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "state.json"), data, 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
}

// TestActivityDotPaletteMatrix exercises the 7-state palette: each state
// drives its own glyph + style combination per PLAN lines 381–389.
func TestActivityDotPaletteMatrix(t *testing.T) {
	t.Parallel()

	cases := []struct {
		state     string
		wantGlyph string
		// wantStyleDescription is non-strict: we only assert that the
		// rendered output contains the glyph and (for blink-on cases)
		// matches the identity / dim alternation contract.
	}{
		{state: "working", wantGlyph: "\U000f06c4"}, // claude icon
		{state: "blocked", wantGlyph: "▲"},
		{state: "done", wantGlyph: "\U000f06c4"},
		{state: "idle", wantGlyph: "\U000f06c4"},
		{state: "starting", wantGlyph: "…"},
		{state: "stopped", wantGlyph: "○"},
		{state: "unknown", wantGlyph: "?"},
	}

	for _, tc := range cases {
		t.Run(tc.state, func(t *testing.T) {
			t.Parallel()
			row := SessionRow{
				ID:           "party-x",
				Status:       "active",
				SessionType:  "standalone",
				PrimaryAgent: "claude",
				State:        tc.state,
			}
			glyph := row.activityGlyph()
			if glyph != tc.wantGlyph {
				t.Fatalf("state %q glyph = %q, want %q", tc.state, glyph, tc.wantGlyph)
			}
		})
	}
}

// TestActivityDotWorkingBlinks confirms that working alternates between
// the identity style (blinkOn) and the dim style (blinkOff). All other
// states render steady (same style regardless of blink).
func TestActivityDotWorkingBlinks(t *testing.T) {
	// Style differences only emit ANSI escapes on a non-Ascii profile.
	lipgloss.SetColorProfile(termenv.TrueColor)
	t.Cleanup(func() { lipgloss.SetColorProfile(termenv.Ascii) })

	row := SessionRow{Status: "active", SessionType: "standalone", PrimaryAgent: "claude", State: "working"}
	on := row.activityDot(true)
	off := row.activityDot(false)
	if on == off {
		t.Fatalf("working dot should alternate; got identical %q in both phases", on)
	}

	for _, st := range []string{"blocked", "done", "idle", "starting", "stopped", "unknown"} {
		row.State = st
		if a, b := row.activityDot(true), row.activityDot(false); a != b {
			t.Fatalf("state %q should be steady; got %q vs %q", st, a, b)
		}
	}
}

// TestStreamingProseSuffix asserts the renderer appends " …" only when
// State=="working" and LastKind is PostToolUse or UserPromptSubmit.
func TestStreamingProseSuffix(t *testing.T) {
	t.Parallel()

	cases := []struct {
		state, lastKind string
		want            bool
	}{
		{"working", "PostToolUse", true},
		{"working", "UserPromptSubmit", true},
		{"working", "PreToolUse", false},
		{"working", "", false},
		{"done", "PostToolUse", false},
		{"idle", "UserPromptSubmit", false},
		{"blocked", "PostToolUse", false},
		{"unknown", "PostToolUse", false},
	}
	for _, tc := range cases {
		got := streamingProseSuffix(tc.state, tc.lastKind)
		if got != tc.want {
			t.Errorf("streamingProseSuffix(%q, %q) = %v, want %v", tc.state, tc.lastKind, got, tc.want)
		}
	}
}

// TestStreamingProseSuffixInRenderedRow checks that the " …" suffix
// reaches the rendered snippet line.
func TestStreamingProseSuffixInRenderedRow(t *testing.T) {
	t.Parallel()

	row := SessionRow{
		ID:           "party-x",
		Title:        "row",
		Status:       "active",
		SessionType:  "standalone",
		PrimaryAgent: "claude",
		State:        "working",
		LastKind:     "PostToolUse",
		Snippet:      "thinking",
	}
	tm := TrackerModel{cursor: -1, sessions: []SessionRow{row}}
	got := tm.renderSessionRow(row, 0, 60)
	if !strings.Contains(got, "thinking …") {
		t.Fatalf("expected streaming-prose suffix on snippet line, got:\n%s", got)
	}
}

// TestComposeSnippetLine verifies the renderer returns the snippet text
// (with optional streaming "…" suffix) and falls back to "" for an empty
// row.
func TestComposeSnippetLine(t *testing.T) {
	t.Parallel()

	cases := []struct {
		name string
		row  SessionRow
		want string
	}{
		{
			name: "snippet only",
			row:  SessionRow{Snippet: "just thinking"},
			want: "just thinking",
		},
		{
			name: "empty",
			row:  SessionRow{},
			want: "",
		},
		{
			name: "streaming suffix",
			row:  SessionRow{Snippet: "writing", State: "working", LastKind: "PostToolUse"},
			want: "writing …",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			got := composeSnippetLine(tc.row)
			if got != tc.want {
				t.Fatalf("composeSnippetLine = %q, want %q", got, tc.want)
			}
		})
	}
}

// TestDoneToIdleObservedTransition verifies that the tracker flips a
// done pane to idle once SeenAt moves past LastEvent. The transition
// runs inside state.UpdateSessionState's flock, so we read back the
// state.json to assert the change persisted.
func TestDoneToIdleObservedTransition(t *testing.T) {
	t.Setenv("PARTY_STATE_ROOT", t.TempDir())

	id := "party-done-to-idle"
	lastEvent := time.Now().UTC().Add(-time.Minute)
	writeStatePhase2Fixture(t, id, "done", "Said: …", "Stop", lastEvent)

	markSessionObserved(id)

	ss, err := state.LoadSessionState(id)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if ss == nil {
		t.Fatal("expected state.json to exist after markSessionObserved")
	}
	if ss.SeenAt.IsZero() {
		t.Fatal("SeenAt should be bumped")
	}
	if ss.Panes["primary"].State != "idle" {
		t.Fatalf("primary state = %q after observation, want idle", ss.Panes["primary"].State)
	}
}

// TestDoneToIdleSkipsHooklessSessions verifies that markSessionObserved
// is a no-op when there's no state.json on disk. The tracker must not
// fabricate state files for sessions that don't have hooks installed.
func TestDoneToIdleSkipsHooklessSessions(t *testing.T) {
	root := t.TempDir()
	t.Setenv("PARTY_STATE_ROOT", root)

	markSessionObserved("party-hookless")

	if _, err := os.Stat(filepath.Join(root, "party-hookless", "state.json")); !os.IsNotExist(err) {
		t.Fatalf("tracker must not create state.json for hookless session, got err=%v", err)
	}
}

// TestDoneToIdleHonorsHookWriteRace verifies the precondition re-check
// inside the flock: if a hook re-wrote the pane to "working" between the
// optimistic decision and the lock acquisition, the tracker MUST NOT
// clobber that transition.
func TestDoneToIdleHonorsHookWriteRace(t *testing.T) {
	t.Setenv("PARTY_STATE_ROOT", t.TempDir())

	id := "party-race"
	// Initial fixture: done state. The tracker would optimistically
	// decide to flip done → idle.
	writeStatePhase2Fixture(t, id, "done", "", "Stop", time.Now().Add(-time.Second))

	// Simulate a concurrent hook write between observation and the
	// flock acquisition by rewriting before markSessionObserved runs.
	writeStatePhase2Fixture(t, id, "working", "Edit foo.go", "PreToolUse", time.Now())

	markSessionObserved(id)

	ss, err := state.LoadSessionState(id)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if ss.Panes["primary"].State != "working" {
		t.Fatalf("tracker clobbered hook-driven working state: got %q", ss.Panes["primary"].State)
	}
}

// TestSubagentSuppressionRendersParentAsBefore is a tracker-side
// regression test for the Phase 1 subagent rule: the hook is what
// filters Claude `agent_id` events so the parent pane never flips. From
// the tracker's perspective state.json already carries the parent pane's
// pre-subagent state — so as long as we render whatever's there, the
// parent stays put. This test asserts the renderer does not invent
// state from elsewhere when a subagent Stop landed.
func TestSubagentSuppressionRendersParentAsBefore(t *testing.T) {
	t.Setenv("PARTY_STATE_ROOT", t.TempDir())

	id := "party-subagent-parent"
	// State.json reflects the parent's true state, "working" — the hook
	// suppressed the subagent's Stop so the file never got a "done"
	// write. Tracker should surface "working" verbatim.
	writeStatePhase2Fixture(t, id, "working", "Agent: investigate", "PreToolUse", time.Now())

	tm := TrackerModel{}
	rows := []SessionRow{{ID: id, Status: "active", SessionType: "standalone", PrimaryAgent: "claude"}}
	tm.updateSnippetActivity(rows, time.Now())

	if rows[0].State != "working" {
		t.Fatalf("parent state = %q, want working (hook suppressed subagent)", rows[0].State)
	}
}

// TestFreshActivityOverridesPreservedSnippet is the regression test for
// the snippet-stickiness bug: when tm.sessions carried a stale Snippet
// from a prior refresh (e.g. "starting…" set the first time the row
// appeared) and the next refresh's state.json carried a fresh Activity
// from sessionactivity.Evaluate (e.g. "Said: …"), the tracker kept
// rendering the stale snippet. preserveLastSnippets filled rows[i].Snippet
// from the prior render, so updateSnippetActivity's "only-if-empty" guard
// skipped the assignment. After the fix, state.json Activity is
// authoritative: it always overwrites the preserved snippet.
func TestFreshActivityOverridesPreservedSnippet(t *testing.T) {
	t.Setenv("PARTY_STATE_ROOT", t.TempDir())

	id := "party-snippet-stick"
	writeStatePhase2Fixture(t, id, "idle", "Said: fresh activity", "Stop", time.Now())

	tm := TrackerModel{sessions: []SessionRow{
		{ID: id, Status: "active", SessionType: "standalone", PrimaryAgent: "claude", Snippet: "starting…"},
	}}

	// Fetcher always emits rows with Snippet="". This snapshot mirrors
	// production: the row carries no snippet of its own, and the prior
	// render's Snippet lives only in tm.sessions.
	snapshot := TrackerSnapshot{Sessions: []SessionRow{
		{ID: id, Status: "active", SessionType: "standalone", PrimaryAgent: "claude"},
	}}
	tm.applySnapshot(snapshot)

	if got, want := tm.sessions[0].Snippet, "Said: fresh activity"; got != want {
		t.Fatalf("snippet = %q, want %q (state.json Activity must overwrite stale preserved snippet)", got, want)
	}
}

// TestPreserveSnippetFallbackWhenNoActivity verifies preserveLastSnippets
// still acts as a fallback for sessions whose state.json yields no
// Activity (e.g. hookless agents). The prior snippet must carry forward.
func TestPreserveSnippetFallbackWhenNoActivity(t *testing.T) {
	t.Setenv("PARTY_STATE_ROOT", t.TempDir())

	id := "party-hookless-carry"
	tm := TrackerModel{sessions: []SessionRow{
		{ID: id, Status: "active", SessionType: "standalone", PrimaryAgent: "claude", Snippet: "carry me"},
	}}

	snapshot := TrackerSnapshot{Sessions: []SessionRow{
		{ID: id, Status: "active", SessionType: "standalone", PrimaryAgent: "claude"},
	}}
	tm.applySnapshot(snapshot)

	if got, want := tm.sessions[0].Snippet, "carry me"; got != want {
		t.Fatalf("snippet = %q, want %q (preserveLastSnippets must still fall back when Evaluate has no Activity)", got, want)
	}
}

// TestActivityFormatterRendersHookEvents asserts that activity strings
// emitted by hooks survive intact through the tracker pipeline into the
// rendered snippet line, for the formatter cases listed in PLAN.md.
func TestActivityFormatterRendersHookEvents(t *testing.T) {
	t.Setenv("PARTY_STATE_ROOT", t.TempDir())

	cases := []struct {
		name     string
		activity string
		lastKind string
		state    string
	}{
		{"edit", "Edit foo.go", "PreToolUse", "working"},
		{"read", "Read README.md", "PreToolUse", "working"},
		{"bash", "Bash: go test ./...", "PreToolUse", "working"},
		{"agent", "Agent: investigate", "PreToolUse", "working"},
		{"search", "Search: foo", "PreToolUse", "working"},
		{"user", "You: please refactor", "UserPromptSubmit", "working"},
		{"said", "Said: done!", "Stop", "done"},
		{"notification", "Notification: needs input", "Notification", "blocked"},
	}
	for i, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			id := "party-formatter-" + tc.name
			writeStatePhase2Fixture(t, id, tc.state, tc.activity, tc.lastKind, time.Now())

			tm := TrackerModel{}
			rows := []SessionRow{{ID: id, Status: "active", SessionType: "standalone", PrimaryAgent: "claude"}}
			tm.updateSnippetActivity(rows, time.Now())

			if rows[0].State != tc.state {
				t.Fatalf("case %d: state = %q, want %q", i, rows[0].State, tc.state)
			}
			if rows[0].Snippet != tc.activity {
				t.Fatalf("case %d: snippet = %q, want %q", i, rows[0].Snippet, tc.activity)
			}
			if rows[0].LastKind != tc.lastKind {
				t.Fatalf("case %d: last_kind = %q, want %q", i, rows[0].LastKind, tc.lastKind)
			}
		})
	}
}
