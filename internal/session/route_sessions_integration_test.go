package session

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/config"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmux/tmuxtest"
	"github.com/alexivison/questmaster/internal/tmuxconfig"
	"github.com/alexivison/questmaster/internal/tmuxroute"
)

// The private server invokes this test binary through a temporary qm shim.
func TestIntegrationCleanupHelper(t *testing.T) {
	if os.Getenv("QM_TEST_CLEANUP_HELPER") != "1" {
		return
	}
	root, socket, id := os.Getenv("QUESTMASTER_STATE_ROOT"), os.Getenv("QM_TEST_SOCKET"), os.Getenv("QM_TEST_CLEANUP_ID")
	store := state.OpenStore(root)
	client := tmux.NewClient(tmux.SocketServer(socket))
	router := tmuxroute.New(store, map[string]*tmux.Client{"default": client, "test_named": client}, func() string { return "default" }, nil)
	svc := NewService(store, client, "")
	svc.Router = router
	if err := svc.SessionClosed(context.Background(), "test_named", id); err != nil {
		_ = os.WriteFile(filepath.Join(root, "helper-error"), []byte(err.Error()), 0o600)
		t.Fatal(err)
	}
}

func privateCleanupServer(t *testing.T) (*state.Store, *tmuxtest.Runner) {
	t.Helper()
	t.Setenv("QUESTMASTER_TMUX_LABEL", "test_named")
	root := t.TempDir()
	t.Setenv("QUESTMASTER_STATE_ROOT", root)
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	shimDir := filepath.Join(t.TempDir(), "qm' #$ path")
	if err := os.MkdirAll(shimDir, 0o700); err != nil {
		t.Fatal(err)
	}
	shim := filepath.Join(shimDir, "questmaster")
	script := "#!/bin/sh\nexport QM_TEST_CLEANUP_HELPER=1\nexport QM_TEST_CLEANUP_ID=\"$6\"\nexec " + config.ShellQuote(exe) + " -test.run '^TestIntegrationCleanupHelper$'\n"
	if err := os.WriteFile(shim, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", shimDir+string(os.PathListSeparator)+os.Getenv("PATH"))
	if err := tmuxconfig.Prepare(root); err != nil {
		t.Fatal(err)
	}
	paths := tmuxconfig.Paths(root)
	runner := tmuxtest.NewRunnerWithConfig(t, paths.Config, paths.Enforced)
	t.Setenv("QM_TEST_SOCKET", runner.Socket())
	store, err := state.NewStore(root)
	if err != nil {
		t.Fatal(err)
	}
	return store, runner
}

func TestIntegrationLastSessionCleanupRuns(t *testing.T) {
	tmuxtest.RequireIntegration(t)
	store, runner := privateCleanupServer(t)
	ids := []string{"qm-cleanup-a", "qm-cleanup-b"}
	for _, id := range ids {
		dir := state.NewRuntimeDir(store.Root(), id)
		if err := os.MkdirAll(dir, 0o700); err != nil {
			t.Fatal(err)
		}
		if err := store.Create(state.Manifest{SessionID: id, TmuxServer: "test_named", Cwd: t.TempDir(), RuntimeDir: dir}); err != nil {
			t.Fatal(err)
		}
		if _, err := runner.Run(t.Context(), "new-session", "-d", "-s", id, "sleep 60"); err != nil {
			t.Fatal(err)
		}
	}
	for _, id := range ids {
		if _, err := runner.Run(t.Context(), "kill-session", "-t", tmux.SessionTarget(id)); err != nil {
			t.Fatal(err)
		}
	}
	waitForCleanupDirs(t, store.Root(), ids...)
}

func waitForCleanupDirs(t *testing.T, root string, ids ...string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		allGone := true
		for _, id := range ids {
			if _, err := os.Stat(state.NewRuntimeDir(root, id)); err == nil {
				allGone = false
			}
		}
		if allGone {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	if data, err := os.ReadFile(filepath.Join(root, "helper-error")); err == nil {
		t.Fatalf("cleanup handler: %s", data)
	}
	t.Fatalf("runtime dirs for %v remain", ids)
}

func TestIntegrationDelayedCleanupDoesNotHarmContinue(t *testing.T) {
	tmuxtest.RequireIntegration(t)
	t.Setenv("SHELL", "/bin/sh")
	store, named := privateCleanupServer(t)
	id := "qm-delayed-cleanup"
	dir := state.NewRuntimeDir(store.Root(), id)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := store.Create(state.Manifest{SessionID: id, TmuxServer: "test_named", RuntimeDir: dir, Cwd: t.TempDir()}); err != nil {
		t.Fatal(err)
	}
	pause := newPauseRunner(named, func(args []string) bool {
		return len(args) > 0 && args[0] == "new-session" && flagVal(args, "-s") == id
	})
	client := tmux.NewClient(pause)
	router := tmuxroute.New(store, map[string]*tmux.Client{"default": tmux.NewClient(tmuxtest.NewRunner(t)), "test_named": client}, func() string { return "test_named" }, nil)
	svc := NewService(store, client, "")
	svc.Router = router
	continued := make(chan error, 1)
	go func() { _, err := svc.Continue(t.Context(), id); continued <- err }()
	<-pause.paused
	closed := make(chan error, 1)
	go func() { closed <- svc.SessionClosed(t.Context(), "test_named", id) }()
	close(pause.release)
	if err := <-continued; err != nil {
		t.Fatal(err)
	}
	if err := <-closed; err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(dir); err != nil {
		t.Fatal("new incarnation's runtime dir removed", err)
	}
}

func TestIntegrationRetireNeutralisesLegacyHook(t *testing.T) {
	tmuxtest.RequireIntegration(t)
	// The legacy hook's test -f gate must see the renamed script after retirement.
	store, named := privateCleanupServer(t)
	legacy := tmuxtest.NewRunner(t)
	id := "qm-retired-legacy"
	dir := state.NewRuntimeDir(store.Root(), id)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	marker := filepath.Join(store.Root(), "legacy-hook-ran")
	invoked := filepath.Join(store.Root(), "legacy-hook-invoked")
	script := "#!/bin/sh\ntouch " + config.ShellQuote(marker) + "\n"
	if err := os.WriteFile(filepath.Join(dir, "cleanup.sh"), []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := store.Create(state.Manifest{SessionID: id, Cwd: t.TempDir(), RuntimeDir: dir, Agents: []state.AgentManifest{{Name: "claude", Role: "agent", CLI: "/bin/sh", ResumeID: "resume-1"}}}); err != nil {
		t.Fatal(err)
	}
	if _, err := legacy.Run(t.Context(), "new-session", "-d", "-s", "qm-survivor", "sleep 60"); err != nil {
		t.Fatal(err)
	}
	if _, err := legacy.Run(t.Context(), "set-option", "-g", "remain-on-exit", "on"); err != nil {
		t.Fatal(err)
	}
	if _, err := legacy.Run(t.Context(), "new-session", "-d", "-s", id, "sh -c 'exit 17'"); err != nil {
		t.Fatal(err)
	}
	if _, err := legacy.Run(t.Context(), "set-hook", "-t", tmux.SessionTarget("qm-survivor"), "session-closed", "run-shell \"touch "+config.ShellQuote(invoked)+"; test -f "+config.ShellQuote(filepath.Join(dir, "cleanup.sh"))+" && /bin/sh "+config.ShellQuote(filepath.Join(dir, "cleanup.sh"))+"\""); err != nil {
		t.Fatal(err)
	}
	panes, err := tmux.NewClient(legacy).ListPanes(t.Context(), id)
	if err != nil || len(panes) != 1 {
		t.Fatalf("panes = %v, %v", panes, err)
	}
	if _, err := legacy.Run(t.Context(), "set-option", "-p", "-t", panes[0].Target(), tmux.PaneRoleOption, tmux.RoleAgent); err != nil {
		t.Fatal(err)
	}
	client := tmux.NewClient(legacy)
	router := tmuxroute.New(store, map[string]*tmux.Client{"default": client, "test_named": tmux.NewClient(named)}, func() string { return "test_named" }, nil)
	svc := NewService(store, client, "")
	svc.Router = router
	if _, err := svc.Continue(t.Context(), id); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(invoked); err == nil {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if _, err := os.Stat(invoked); err != nil {
		t.Fatal("legacy hook did not fire", err)
	}
	if _, err := os.Stat(marker); err == nil {
		t.Fatal("retired legacy hook ran cleanup script")
	}
	if _, err := os.Stat(filepath.Join(dir, "cleanup.sh.retired")); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dir, "cleanup.sh")); err == nil {
		t.Fatal("legacy cleanup script still active")
	}
	if _, err := named.Run(t.Context(), "has-session", "-t", tmux.SessionTarget(id)); err != nil {
		t.Fatal("session not recreated on creation server", err)
	}
}
