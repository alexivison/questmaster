package tui

import (
	"fmt"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

func stubResolver(info SessionInfo) SessionResolver {
	return func() (SessionInfo, error) { return info, nil }
}

func TestModelInitReturnsCommand(t *testing.T) {
	t.Parallel()

	m := NewModelWithResolver(stubResolver(SessionInfo{ID: "party-test"}))
	if cmd := m.Init(); cmd == nil {
		t.Fatal("expected init command")
	}
}

func TestModelErrorStateRendersMessage(t *testing.T) {
	t.Parallel()

	m := NewModelWithResolver(func() (SessionInfo, error) {
		return SessionInfo{}, fmt.Errorf("no party session found")
	})
	updated, _ := m.Update(sessionMsg{err: fmt.Errorf("no party session found")})
	model := updated.(Model)
	model.Width = 80
	model.Height = 24

	view := model.View()
	if !strings.Contains(view, "no party session found") {
		t.Fatalf("expected error message, got:\n%s", view)
	}
	if !strings.Contains(view, "PARTY_SESSION") {
		t.Fatalf("expected PARTY_SESSION hint, got:\n%s", view)
	}
}

func TestModelViewUsesUnifiedTracker(t *testing.T) {
	t.Parallel()

	current := SessionInfo{ID: "party-master", SessionType: "master"}
	m := NewModelWithResolver(stubResolver(current))
	m.tracker = NewTrackerModel(current, snapshotFetcher(TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "party-master", Title: "master", Status: "active", SessionType: "master", IsCurrent: true},
			{ID: "party-worker", Title: "worker", Status: "active", SessionType: "worker", ParentID: "party-master"},
		},
		Current: CurrentSessionDetail{
			ID:              "party-master",
			SessionType:     "master",
			CompanionName:   "codex",
			CompanionStatus: CompanionStatus{State: CompanionIdle},
		},
	}), &fakeActions{})
	m.Width = 80
	m.Height = 24

	updated, _ := m.Update(sessionMsg{info: current})
	model := updated.(Model)
	view := model.View()

	if !strings.Contains(view, "Party: party-master") {
		t.Fatalf("expected unified tracker title, got:\n%s", view)
	}
	// Master sessions show role + workers count instead of the companion line.
	if !strings.Contains(view, "role: master") {
		t.Fatalf("expected role line for master session, got:\n%s", view)
	}
	if !strings.Contains(view, "●") {
		t.Fatalf("expected tracker content, got:\n%s", view)
	}
}

func TestModelIgnoresForeignResolvedSession(t *testing.T) {
	t.Parallel()

	m := NewModelWithResolver(stubResolver(SessionInfo{ID: "party-a", SessionType: "worker"}))
	updated, _ := m.Update(sessionMsg{info: SessionInfo{ID: "party-a", SessionType: "worker"}})
	model := updated.(Model)

	updated, _ = model.Update(sessionMsg{info: SessionInfo{ID: "party-b", SessionType: "master"}})
	model = updated.(Model)
	if model.SessionID != "party-a" {
		t.Fatalf("expected session identity to stay locked, got %q", model.SessionID)
	}
}

func TestModelTickReturnsCommand(t *testing.T) {
	t.Parallel()

	m := NewModelWithResolver(stubResolver(SessionInfo{ID: "party-tick"}))
	if _, cmd := m.Update(tickMsg{}); cmd == nil {
		t.Fatal("expected tick command")
	}
}

func TestModelWindowSizeShrinkClearsScreen(t *testing.T) {
	t.Parallel()

	m := NewModelWithResolver(stubResolver(SessionInfo{ID: "party-sz"}))
	m.Width = 80
	m.Height = 40

	if _, cmd := m.Update(tea.WindowSizeMsg{Width: 80, Height: 24}); cmd == nil {
		t.Fatal("expected clear screen on shrink")
	}
}

func TestDisambiguatePartySessions(t *testing.T) {
	t.Parallel()

	id, err := disambiguatePartySessions([]string{"party-one", "misc"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if id != "party-one" {
		t.Fatalf("expected party-one, got %q", id)
	}

	if _, err := disambiguatePartySessions([]string{"party-one", "party-two"}); err == nil {
		t.Fatal("expected ambiguity error")
	}
}

func TestTruncate(t *testing.T) {
	t.Parallel()

	if got := truncate("hello world", 8); got != "hello w…" {
		t.Fatalf("unexpected truncate result %q", got)
	}
}
