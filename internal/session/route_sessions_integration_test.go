package session

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"strings"
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
	router := tmuxroute.New(store, map[string]*tmux.Client{"questmaster": client, "test_named": client}, func() string { return "questmaster" }, nil)
	svc := NewService(store, client, "")
	svc.Router = router
	if err := svc.SessionClosed(context.Background(), "test_named", id); err != nil {
		_ = os.WriteFile(filepath.Join(root, "helper-error"), []byte(err.Error()), 0o600)
		t.Fatal(err)
	}
}

func privateCleanupServer(t *testing.T, roots ...string) (*state.Store, *tmuxtest.Runner) {
	t.Helper()
	t.Setenv("QUESTMASTER_TMUX_LABEL", "test_named")
	root := t.TempDir()
	if len(roots) > 0 {
		root = roots[0]
	}
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

func TestIntegrationContinueMasterAfterCloseHooks(t *testing.T) {
	tmuxtest.RequireIntegration(t)
	for _, order := range [][]string{
		{"qm-worker", "qm-master"},
		{"qm-master", "qm-worker"},
		{"qm-worker"},
	} {
		t.Run(strings.Join(order, " then "), func(t *testing.T) {
			t.Setenv("HOME", t.TempDir())
			t.Setenv("SHELL", "/bin/sh")
			store, runner := privateCleanupServer(t)
			client := tmux.NewClient(runner)
			svc := NewService(store, client, "")
			svc.Router = tmuxroute.New(store, map[string]*tmux.Client{"test_named": client}, func() string { return "test_named" }, nil)
			cli := filepath.Join(t.TempDir(), "test-agent")
			if err := os.WriteFile(cli, []byte("#!/bin/sh\nexec /bin/sleep 60\n"), 0o700); err != nil {
				t.Fatal(err)
			}
			master, worker := "qm-master", "qm-worker"
			for _, id := range []string{master, worker} {
				createTestManifest(t, store, id, id, t.TempDir(), "")
				if err := store.Update(id, func(m *state.Manifest) {
					m.TmuxServer = "test_named"
					m.Agents[0].CLI = cli
					if id == worker {
						m.SetExtra("parent_session", master)
					}
				}); err != nil {
					t.Fatal(err)
				}
			}
			if err := store.AddWorker(master, worker); err != nil {
				t.Fatal(err)
			}
			if _, err := svc.Continue(t.Context(), master); err != nil {
				t.Fatal(err)
			}
			for _, id := range order {
				if err := client.KillSession(t.Context(), id); err != nil {
					t.Fatal(err)
				}
			}
			waitForCleanupDirs(t, store.Root(), order...)
			result, err := svc.Continue(t.Context(), master)
			if err != nil {
				t.Fatal(err)
			}
			if !slices.Equal(result.RevivedWorkers, []string{worker}) || len(result.FailedWorkers) != 0 {
				t.Fatalf("Continue after close hooks = %+v", result)
			}
			if alive, err := client.HasSession(t.Context(), worker); err != nil || !alive {
				t.Fatalf("continued worker alive = %v, %v", alive, err)
			}
		})
	}
}

func waitForCleanupDirs(t *testing.T, root string, ids ...string) {
	t.Helper()
	deadline := time.Now().Add(sessionIntegrationWaitTimeout)
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
	router := tmuxroute.New(store, map[string]*tmux.Client{"questmaster": tmux.NewClient(tmuxtest.NewRunner(t)), "test_named": client}, func() string { return "test_named" }, nil)
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
