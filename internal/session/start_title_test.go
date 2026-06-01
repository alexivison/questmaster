//go:build linux || darwin

package session

import (
	"context"
	"testing"

	"github.com/alexivison/questmaster/internal/agent"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
)

func newTitleTestService(t *testing.T) *Service {
	t.Helper()
	store, err := state.NewStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	runner := &testRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) > 0 && args[0] == "has-session" {
			return "", &tmux.ExitError{Code: 1} // no existing tmux session
		}
		return "", nil
	}}
	registry, err := agent.NewRegistry(&agent.Config{
		Agents: map[string]agent.AgentConfig{"claude": {CLI: "/bin/sh"}},
		Roles:  agent.RolesConfig{Primary: &agent.RoleConfig{Agent: "claude", Window: -1}},
	})
	if err != nil {
		t.Fatal(err)
	}
	return &Service{
		Store:       store,
		Client:      tmux.NewClient(runner),
		Registry:    registry,
		Now:         func() int64 { return 100 },
		RandSuffix:  func() int64 { return 42 },
		CLIResolver: func(string) (string, error) { return "echo noop", nil },
	}
}

func TestStart_DerivesTitleFromPromptWhenBlank(t *testing.T) {
	svc := newTitleTestService(t)

	result, err := svc.Start(t.Context(), StartOpts{
		Cwd:    t.TempDir(),
		Prompt: "fix the broken login flow please",
	})
	if err != nil {
		t.Fatalf("Start: %v", err)
	}

	m, err := svc.Store.Read(result.SessionID)
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}
	if m.Title != "fix the broken login flow please" {
		t.Fatalf("derived title = %q, want %q", m.Title, "fix the broken login flow please")
	}
	if m.ExtraString("title_locked") != "" {
		t.Fatalf("auto-derived title should not be locked, got %q", m.ExtraString("title_locked"))
	}
}

func TestStart_KeepsExplicitTitleAndLocksIt(t *testing.T) {
	svc := newTitleTestService(t)

	result, err := svc.Start(t.Context(), StartOpts{
		Cwd:    t.TempDir(),
		Title:  "release triage",
		Prompt: "fix the broken login flow please",
	})
	if err != nil {
		t.Fatalf("Start: %v", err)
	}

	m, err := svc.Store.Read(result.SessionID)
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}
	if m.Title != "release triage" {
		t.Fatalf("explicit title = %q, want %q", m.Title, "release triage")
	}
	if m.ExtraString("title_locked") != "1" {
		t.Fatalf("explicit title should be locked, got %q", m.ExtraString("title_locked"))
	}
}

func TestStart_BlankTitleNoPromptStaysBlank(t *testing.T) {
	svc := newTitleTestService(t)

	result, err := svc.Start(t.Context(), StartOpts{Cwd: t.TempDir()})
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	m, err := svc.Store.Read(result.SessionID)
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}
	if m.Title != "" {
		t.Fatalf("title = %q, want blank", m.Title)
	}
	if m.ExtraString("title_locked") != "" {
		t.Fatalf("blank title should not be locked, got %q", m.ExtraString("title_locked"))
	}
}
