package session

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmux/tmuxtest"
	"github.com/alexivison/questmaster/internal/tmuxconfig"
	"github.com/alexivison/questmaster/internal/tmuxroute"
)

type foreignServerRaceRunner struct {
	own, foreign tmux.Server
	appeared     bool
}

func (r *foreignServerRaceRunner) Run(ctx context.Context, args ...string) (string, error) {
	if args[0] == "new-session" && !r.appeared {
		r.appeared = true
		if _, err := r.foreign.Run(ctx, "new-session", "-d", "-s", "qm-foreign-sentinel", "sleep 60"); err != nil {
			return "", err
		}
	}
	return r.own.Run(ctx, args...)
}

func TestIntegrationStartRejectsForeignServerAfterPreflight(t *testing.T) {
	svc, runner, foreignRoot := foreignServerRaceService(t)
	result, startErr := svc.Start(t.Context(), StartOpts{Shell: true, Cwd: t.TempDir()})
	marker, markerErr := runner.own.Run(t.Context(), "show-options", "-gqv", "@questmaster_root")
	if markerErr != nil {
		t.Fatal(markerErr)
	}
	t.Logf("Start=%+v, err=%v, marker belongs to foreign root=%v", result, startErr, tmuxconfig.OwnsRoot(marker, foreignRoot, "test_named"))
	if startErr == nil || !tmuxconfig.OwnsRoot(marker, foreignRoot, "test_named") {
		t.Fatal("Start adopted the foreign server after the absence probe")
	}
	assertOnlyForeignSentinel(t, runner)
}

func TestIntegrationContinueRejectsForeignServerAfterPreflight(t *testing.T) {
	svc, runner, _ := foreignServerRaceService(t)
	id := "qm-resume-foreign"
	if err := svc.Store.Create(state.Manifest{TmuxServer: "questmaster", SessionID: id, Cwd: t.TempDir()}); err != nil {
		t.Fatal(err)
	}
	if _, err := svc.Continue(t.Context(), id); err == nil {
		t.Fatal("Continue adopted the foreign server")
	}
	m, err := svc.Store.Read(id)
	if err != nil || m.TmuxServer != "questmaster" {
		t.Fatalf("route after rollback = %q, %v", m.TmuxServer, err)
	}
	assertOnlyForeignSentinel(t, runner)
}

func foreignServerRaceService(t *testing.T) (*Service, *foreignServerRaceRunner, string) {
	t.Helper()
	tmuxtest.RequireIntegration(t)
	t.Setenv("QUESTMASTER_TMUX_LABEL", "test_named")
	t.Setenv("SHELL", "/bin/sh")
	svc, legacy := setupService(t)
	shimDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(shimDir, "questmaster"), []byte("#!/bin/sh\nexit 0\n"), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", shimDir+":"+os.Getenv("PATH"))
	foreignRoot := t.TempDir()
	if err := tmuxconfig.Prepare(foreignRoot); err != nil {
		t.Fatal(err)
	}
	ownPaths, foreignPaths := tmuxconfig.Paths(svc.Store.Root()), tmuxconfig.Paths(foreignRoot)
	socket := tmuxtest.NewRunner(t).Socket()
	runner := &foreignServerRaceRunner{own: tmux.SocketServerWithConfig(socket, ownPaths.Config, ownPaths.Enforced), foreign: tmux.SocketServerWithConfig(socket, foreignPaths.Config, foreignPaths.Enforced)}
	svc.Router = tmuxroute.New(svc.Store, map[string]*tmux.Client{"questmaster": tmux.NewClient(legacy), "test_named": tmux.NewClient(runner)}, func() string { return "test_named" }, nil)
	return svc, runner, foreignRoot
}

func assertOnlyForeignSentinel(t *testing.T, runner *foreignServerRaceRunner) {
	t.Helper()
	if sessions, err := runner.own.Run(t.Context(), "list-sessions", "-F", "#{session_name}"); err != nil || sessions != "qm-foreign-sentinel" {
		t.Fatalf("rollback sessions = %q, %v; want only foreign sentinel", sessions, err)
	}
}
