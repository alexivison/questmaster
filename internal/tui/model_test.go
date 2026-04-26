package tui

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/anthropics/ai-party/tools/party-cli/internal/agent"
	"github.com/anthropics/ai-party/tools/party-cli/internal/state"
	"github.com/anthropics/ai-party/tools/party-cli/internal/tmux"
)

func stubResolver(info SessionInfo) SessionResolver {
	return func() (SessionInfo, error) { return info, nil }
}

type modelMockRunner struct {
	fn    func(ctx context.Context, args ...string) (string, error)
	calls int
}

func (m *modelMockRunner) Run(ctx context.Context, args ...string) (string, error) {
	m.calls++
	return m.fn(ctx, args...)
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

	current := SessionInfo{ID: "party-master"}
	m := NewModelWithResolver(stubResolver(current))
	m.tracker = NewTrackerModel(current, snapshotFetcher(TrackerSnapshot{
		Sessions: []SessionRow{
			{ID: "party-master", Title: "master", Status: "active", SessionType: "master", IsCurrent: true},
			{ID: "party-worker", Title: "worker", Status: "active", SessionType: "worker", ParentID: "party-master"},
		},
		Current: CurrentSessionDetail{
			SessionType: "master",
		},
	}), &fakeActions{})
	m.Width = 80
	m.Height = 24

	updated, cmd := m.Update(sessionMsg{info: current})
	model := updated.(Model)
	if cmd == nil {
		t.Fatal("expected async snapshot command")
	}
	msg := cmd()
	updated, _ = model.Update(msg)
	model = updated.(Model)
	view := model.View()

	if !strings.Contains(view, "party-master") {
		t.Fatalf("expected unified tracker title, got:\n%s", view)
	}
	if strings.Contains(view, "Master:") {
		t.Fatalf("did not expect legacy role-badge tracker title, got:\n%s", view)
	}
	if strings.Contains(view, "role:") {
		t.Fatalf("did not expect legacy role line for master session, got:\n%s", view)
	}
	if !strings.Contains(view, "●") {
		t.Fatalf("expected tracker content, got:\n%s", view)
	}
}

func TestModelSessionUpdateSchedulesSnapshotWithoutBlocking(t *testing.T) {
	current := SessionInfo{ID: "party-async"}
	started := make(chan struct{}, 1)
	release := make(chan struct{})

	m := NewModelWithResolver(stubResolver(current))
	m.tracker = NewTrackerModel(current, func(SessionInfo) (TrackerSnapshot, error) {
		started <- struct{}{}
		<-release
		return TrackerSnapshot{
			Sessions: []SessionRow{{ID: "party-async", Status: "active", SessionType: "standalone", IsCurrent: true}},
			Current:  CurrentSessionDetail{SessionType: "standalone"},
		}, nil
	}, &fakeActions{})

	done := make(chan struct {
		model Model
		cmd   tea.Cmd
	}, 1)
	go func() {
		updated, cmd := m.Update(sessionMsg{info: current})
		done <- struct {
			model Model
			cmd   tea.Cmd
		}{model: updated.(Model), cmd: cmd}
	}()

	select {
	case result := <-done:
		if result.cmd == nil {
			t.Fatal("expected snapshot command")
		}
		select {
		case <-started:
			t.Fatal("fetcher should not run inside Update")
		default:
		}

		msgs := make(chan tea.Msg, 1)
		go func() {
			msgs <- result.cmd()
		}()

		select {
		case <-started:
		case <-time.After(200 * time.Millisecond):
			t.Fatal("expected async fetcher to start once command runs")
		}

		select {
		case <-msgs:
			t.Fatal("snapshot command returned before fetcher was released")
		case <-time.After(50 * time.Millisecond):
		}

		close(release)

		select {
		case msg := <-msgs:
			if _, ok := msg.(snapshotMsg); !ok {
				t.Fatalf("expected snapshotMsg, got %T", msg)
			}
		case <-time.After(200 * time.Millisecond):
			t.Fatal("expected snapshot command to deliver after release")
		}

	case <-time.After(200 * time.Millisecond):
		t.Fatal("Update blocked on snapshot fetch")
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

func TestAutoResolverCachesResolvedSessionInfo(t *testing.T) {
	store, err := state.NewStore(t.TempDir())
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	if err := store.Create(state.Manifest{PartyID: "party-cache", Title: "cached"}); err != nil {
		t.Fatalf("create manifest: %v", err)
	}

	t.Setenv("PARTY_SESSION", "")
	t.Setenv("TMUX", "1")
	runner := &modelMockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) > 0 && args[0] == "display-message" {
			return "party-cache", nil
		}
		return "", fmt.Errorf("unexpected command %v", args)
	}}
	resolver := newAutoResolver(store, tmux.NewClient(runner))

	first, err := resolver.Resolve()
	if err != nil {
		t.Fatalf("first resolve: %v", err)
	}
	second, err := resolver.Resolve()
	if err != nil {
		t.Fatalf("second resolve: %v", err)
	}
	if first.Title != "cached" || second.Title != "cached" {
		t.Fatalf("unexpected titles: %#v %#v", first, second)
	}
	if runner.calls != 1 {
		t.Fatalf("expected one discovery call across cache miss+hit, got %d", runner.calls)
	}
}

func TestAutoResolverInvalidatesOnManifestMTimeChange(t *testing.T) {
	store, err := state.NewStore(t.TempDir())
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	if err := store.Create(state.Manifest{PartyID: "party-manifest", Title: "before"}); err != nil {
		t.Fatalf("create manifest: %v", err)
	}

	t.Setenv("PARTY_SESSION", "party-manifest")
	resolver := newAutoResolver(store, tmux.NewClient(&modelMockRunner{fn: func(context.Context, ...string) (string, error) {
		return "", nil
	}}))

	first, err := resolver.Resolve()
	if err != nil {
		t.Fatalf("first resolve: %v", err)
	}
	if first.Title != "before" {
		t.Fatalf("first title: got %q", first.Title)
	}

	time.Sleep(20 * time.Millisecond)
	if err := store.Update("party-manifest", func(m *state.Manifest) {
		m.Title = "after"
	}); err != nil {
		t.Fatalf("update manifest: %v", err)
	}

	second, err := resolver.Resolve()
	if err != nil {
		t.Fatalf("second resolve: %v", err)
	}
	if second.Title != "after" {
		t.Fatalf("expected manifest invalidation to reload title, got %q", second.Title)
	}
}

func TestAutoResolverInvalidatesOnConfigMTimeChange(t *testing.T) {
	store, err := state.NewStore(t.TempDir())
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	if err := store.Create(state.Manifest{PartyID: "party-config"}); err != nil {
		t.Fatalf("create manifest: %v", err)
	}

	xdg := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", xdg)
	t.Setenv("PARTY_SESSION", "party-config")
	configPath := filepath.Join(xdg, "party-cli", "config.toml")
	if err := os.MkdirAll(filepath.Dir(configPath), 0o755); err != nil {
		t.Fatalf("mkdir config dir: %v", err)
	}
	writeConfig := func(body string) {
		t.Helper()
		if err := os.WriteFile(configPath, []byte(body), 0o644); err != nil {
			t.Fatalf("write config: %v", err)
		}
	}

	writeConfig(`
[roles.primary]
agent = "codex"
window = -1

[roles.companion]
agent = "claude"
window = 0
`)
	resolver := newAutoResolver(store, tmux.NewClient(&modelMockRunner{fn: func(context.Context, ...string) (string, error) {
		return "", nil
	}}))

	first, err := resolver.Resolve()
	if err != nil {
		t.Fatalf("first resolve: %v", err)
	}
	firstPrimary, err := first.Registry.ForRole(agent.RolePrimary)
	if err != nil {
		t.Fatalf("first primary binding: %v", err)
	}
	if firstPrimary.Agent.Name() != "codex" {
		t.Fatalf("first primary agent: got %q", firstPrimary.Agent.Name())
	}

	time.Sleep(20 * time.Millisecond)
	writeConfig(`
[roles.primary]
agent = "claude"
window = -1

[roles.companion]
agent = "codex"
window = 0
`)

	second, err := resolver.Resolve()
	if err != nil {
		t.Fatalf("second resolve: %v", err)
	}
	secondPrimary, err := second.Registry.ForRole(agent.RolePrimary)
	if err != nil {
		t.Fatalf("second primary binding: %v", err)
	}
	if secondPrimary.Agent.Name() != "claude" {
		t.Fatalf("expected config invalidation to rebuild registry, got %q", secondPrimary.Agent.Name())
	}
}
