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

// TestDoneToIdleGraceWindow verifies the 5s grace window: a "done" pane
// must stay done until at least doneToIdleGrace has elapsed since the
// most recent hook event. Without the grace, the per-session tracker
// pane (which refreshes ~1s) clobbers the cyan glyph before anyone sees
// it.
func TestDoneToIdleGraceWindow(t *testing.T) {
	cases := []struct {
		name      string
		sinceLast time.Duration
		wantState string
	}{
		{name: "within_grace", sinceLast: 1 * time.Second, wantState: "done"},
		{name: "past_grace", sinceLast: 6 * time.Second, wantState: "idle"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("PARTY_STATE_ROOT", t.TempDir())

			id := "party-grace-" + tc.name
			writeStatePhase2Fixture(t, id, "done", "Said: …", "Stop", time.Now().UTC().Add(-tc.sinceLast))

			markSessionObserved(id)

			ss, err := state.LoadSessionState(id)
			if err != nil {
				t.Fatalf("load: %v", err)
			}
			if ss == nil {
				t.Fatal("expected state.json after markSessionObserved")
			}
			if got := ss.Panes["primary"].State; got != tc.wantState {
				t.Fatalf("primary state = %q, want %q (sinceLast=%s, grace=%s)",
					got, tc.wantState, tc.sinceLast, doneToIdleGrace)
			}
		})
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

// TestStatusWordPerState verifies every supported State maps to its literal
// word, and unknown / empty values collapse to "unknown".
func TestStatusWordPerState(t *testing.T) {
	t.Parallel()

	cases := map[string]string{
		"working":  "working",
		"blocked":  "blocked",
		"done":     "done",
		"idle":     "idle",
		"starting": "starting",
		"stopped":  "stopped",
		"unknown":  "unknown",
		"":         "unknown",
		"garbage":  "unknown",
	}
	for state, want := range cases {
		got := SessionRow{State: state}.statusWord()
		if got != want {
			t.Errorf("statusWord(%q) = %q, want %q", state, got, want)
		}
	}
}

// TestStatusWordStyleSteady verifies the status word color is steady: it
// always uses identityStyle for working (never dim) and the per-state color
// for the remaining states. The activity glyph owns the blink; the word
// owns the steady state signal.
func TestStatusWordStyleSteady(t *testing.T) {
	t.Parallel()

	cases := []struct {
		state string
		want  lipgloss.Color
	}{
		{"working", identityStyle("standalone").GetForeground().(lipgloss.Color)},
		{"blocked", blockedGlyphStyle.GetForeground().(lipgloss.Color)},
		{"done", doneGlyphStyle.GetForeground().(lipgloss.Color)},
		{"idle", idleGlyphStyle.GetForeground().(lipgloss.Color)},
		{"starting", idleGlyphStyle.GetForeground().(lipgloss.Color)},
		{"stopped", stoppedGlyphStyle.GetForeground().(lipgloss.Color)},
		{"unknown", stoppedGlyphStyle.GetForeground().(lipgloss.Color)},
	}
	for _, tc := range cases {
		row := SessionRow{Status: "active", SessionType: "standalone", PrimaryAgent: "claude", State: tc.state}
		got, ok := row.statusWordStyle().GetForeground().(lipgloss.Color)
		if !ok {
			t.Errorf("state %q: foreground is not lipgloss.Color", tc.state)
			continue
		}
		if got != tc.want {
			t.Errorf("state %q: status word color = %q, want %q", tc.state, got, tc.want)
		}
		// Working must never render with the dim activity color.
		if tc.state == "working" {
			dim, _ := dimActivityStyle.GetForeground().(lipgloss.Color)
			if got == dim {
				t.Errorf("state %q: working status word must not be dim", tc.state)
			}
		}
	}
}

// TestActivityDotStyleRoleBased verifies the activity glyph color is
// role-based for active rows regardless of state. Working blink-off is the
// one state-dependent variant (dim grey for the off-frame); every other
// state renders in the session-type identity color.
func TestActivityDotStyleRoleBased(t *testing.T) {
	t.Parallel()

	roles := []string{"master", "worker", "standalone"}
	states := []string{"working", "blocked", "done", "idle", "starting", "unknown"}
	for _, role := range roles {
		wantFG, _ := identityStyle(role).GetForeground().(lipgloss.Color)
		for _, state := range states {
			row := SessionRow{Status: "active", SessionType: role, PrimaryAgent: "claude", State: state}
			gotFG, ok := row.activityDotStyle(true).GetForeground().(lipgloss.Color)
			if !ok {
				t.Errorf("role %q state %q: foreground is not lipgloss.Color", role, state)
				continue
			}
			if gotFG != wantFG {
				t.Errorf("role %q state %q: dot color = %q, want role identity %q", role, state, gotFG, wantFG)
			}
		}
		// Working blink-off frame uses the dim activity color.
		workingOff := SessionRow{Status: "active", SessionType: role, PrimaryAgent: "claude", State: "working"}.activityDotStyle(false)
		dimFG, _ := dimActivityStyle.GetForeground().(lipgloss.Color)
		offFG, _ := workingOff.GetForeground().(lipgloss.Color)
		if offFG != dimFG {
			t.Errorf("role %q: working blink-off color = %q, want dim %q", role, offFG, dimFG)
		}
	}

	// Inactive rows stay in the muted stopped color.
	stoppedFG, _ := SessionRow{Status: "stopped", SessionType: "standalone", State: "stopped"}.activityDotStyle(true).GetForeground().(lipgloss.Color)
	wantStopped, _ := stoppedGlyphStyle.GetForeground().(lipgloss.Color)
	if stoppedFG != wantStopped {
		t.Errorf("inactive row color = %q, want stoppedGlyphStyle %q", stoppedFG, wantStopped)
	}
}

// TestRenderSessionRowSeparatorIsDim verifies the ' - ' literal between the
// title and the status word renders in the same faint/meta style used for
// the path/ID line, not the (potentially bold) title color. Forces a
// TrueColor profile so styles emit ANSI segments we can match on.
func TestRenderSessionRowSeparatorIsDim(t *testing.T) {
	lipgloss.SetColorProfile(termenv.TrueColor)
	t.Cleanup(func() { lipgloss.SetColorProfile(termenv.Ascii) })

	row := SessionRow{
		ID:           "party-x",
		Title:        "AI Party",
		Status:       "active",
		SessionType:  "standalone",
		PrimaryAgent: "claude",
		State:        "working",
	}
	tm := TrackerModel{cursor: -1, sessions: []SessionRow{row}}
	got := tm.renderSessionRow(row, 0, 60)
	titleLine := strings.SplitN(got, "\n", 2)[0]

	wantSeparator := metaTextStyle.Render(statusSeparator)
	if !strings.Contains(titleLine, wantSeparator) {
		t.Fatalf("expected separator rendered with metaTextStyle (faint); got:\n%q\nwant substring:\n%q", titleLine, wantSeparator)
	}

	// Cross-check: the old behaviour rendered the separator with titleStyle
	// (sessionTitleStyle has no foreground/faint), which would emit nothing
	// styled. Confirm we're NOT emitting the bare " - " sans styling.
	bareSeparator := sessionTitleStyle.Render(statusSeparator)
	if wantSeparator == bareSeparator {
		t.Fatalf("metaTextStyle render must differ from titleStyle render under TrueColor; both produced %q", wantSeparator)
	}
}

// TestDividerLineStyleMatchesTmuxInactiveBorder pins the tracker's title
// separator to tmux's pane-border-style hex (#373e47 in dotfiles/.tmux.conf)
// so the two lines render as a single continuous rule.
func TestDividerLineStyleMatchesTmuxInactiveBorder(t *testing.T) {
	t.Parallel()

	got, ok := dividerLineStyle.GetForeground().(lipgloss.Color)
	if !ok {
		t.Fatalf("dividerLineStyle foreground is not lipgloss.Color: %T", dividerLineStyle.GetForeground())
	}
	const want = lipgloss.Color("#373e47")
	if got != want {
		t.Fatalf("dividerLineStyle foreground = %q, want tmux inactive border %q", got, want)
	}
}

// TestRenderSessionRowAppendsStatusWord checks the basic appearance: each
// state renders the literal word at the end of the title line.
func TestRenderSessionRowAppendsStatusWord(t *testing.T) {
	t.Parallel()

	for _, state := range []string{"working", "blocked", "done", "idle", "starting", "stopped", "unknown"} {
		row := SessionRow{
			ID:           "party-x",
			Title:        "AI Party",
			Status:       "active",
			SessionType:  "standalone",
			PrimaryAgent: "claude",
			State:        state,
		}
		tm := TrackerModel{cursor: -1, sessions: []SessionRow{row}}
		got := tm.renderSessionRow(row, 0, 60)
		want := "AI Party - " + state
		if !strings.Contains(got, want) {
			t.Errorf("state %q: expected %q in title line, got:\n%s", state, want, got)
		}
	}
}

// TestRenderSessionRowTruncatesTitleKeepsStatus verifies the width budget:
// at a narrow innerW the title is truncated with '…' but the state word
// stays intact.
func TestRenderSessionRowTruncatesTitleKeepsStatus(t *testing.T) {
	t.Parallel()

	row := SessionRow{
		ID:           "party-x",
		Title:        "A very very very looooooooooooooooooong title",
		Status:       "active",
		SessionType:  "standalone",
		PrimaryAgent: "claude",
		State:        "working",
	}
	tm := TrackerModel{cursor: -1, sessions: []SessionRow{row}}

	const innerW = 30
	got := tm.renderSessionRow(row, 0, innerW)
	titleLine := strings.SplitN(got, "\n", 2)[0]

	if !strings.Contains(titleLine, " - working") {
		t.Fatalf("status word lost on narrow row; got:\n%s", titleLine)
	}
	if !strings.Contains(titleLine, "…") {
		t.Fatalf("expected ellipsis on truncated title; got:\n%s", titleLine)
	}
	if strings.Contains(titleLine, row.Title) {
		t.Fatalf("expected title to be truncated, but full title appears:\n%s", titleLine)
	}
}

// TestRenderSessionRowTitleFitsWithoutEllipsis verifies a title that fits
// inside the budget keeps its full text (no spurious truncation).
func TestRenderSessionRowTitleFitsWithoutEllipsis(t *testing.T) {
	t.Parallel()

	row := SessionRow{
		ID:           "party-x",
		Title:        "AI Party",
		Status:       "active",
		SessionType:  "standalone",
		PrimaryAgent: "claude",
		State:        "working",
	}
	tm := TrackerModel{cursor: -1, sessions: []SessionRow{row}}
	got := tm.renderSessionRow(row, 0, 60)
	titleLine := strings.SplitN(got, "\n", 2)[0]

	if !strings.Contains(titleLine, "AI Party - working") {
		t.Fatalf("expected full title + status; got:\n%s", titleLine)
	}
	if strings.Contains(titleLine, "AI Party…") || strings.Contains(titleLine, "AI Part…") {
		t.Fatalf("title should not be truncated at innerW=60; got:\n%s", titleLine)
	}
}

// TestTruncateTitleForStatusBudget covers the edge cases of the width
// helper: zero/negative budgets drop the title, budget=1 yields '…', a
// large budget passes the title through unchanged, and an intermediate
// budget appends '…'.
func TestTruncateTitleForStatusBudget(t *testing.T) {
	t.Parallel()

	cases := []struct {
		name   string
		title  string
		budget int
		want   string
	}{
		{"zero budget drops title", "hello", 0, ""},
		{"negative budget drops title", "hello", -3, ""},
		{"budget 1 collapses to ellipsis", "hello", 1, "…"},
		{"budget fits exactly", "hello", 5, "hello"},
		{"budget larger than title", "hi", 10, "hi"},
		{"budget cuts with ellipsis", "investigate", 5, "inve…"},
	}
	for _, tc := range cases {
		got := truncateTitleForStatus(tc.title, tc.budget)
		if got != tc.want {
			t.Errorf("%s: got %q, want %q", tc.name, got, tc.want)
		}
	}
}
