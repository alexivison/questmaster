package session

import (
	"context"
	"errors"
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
	"github.com/fsnotify/fsnotify"
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

func cleanupHelperDonePath(root, id string) string {
	return filepath.Join(root, "cleanup-helper-done-"+id)
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
	script := "#!/bin/sh\n" +
		"export QM_TEST_CLEANUP_HELPER=1\n" +
		"export QM_TEST_CLEANUP_ID=\"$6\"\n" +
		"export QM_TEST_CLEANUP_DONE_DIR=" + config.ShellQuote(root) + "\n" +
		config.ShellQuote(exe) + " -test.run '^TestIntegrationCleanupHelper$'\n" +
		"helper_exit_code=$?\n" +
		"printf '%s\\n' \"$helper_exit_code\" > \"$QM_TEST_CLEANUP_DONE_DIR/cleanup-helper-done-$QM_TEST_CLEANUP_ID\"\n" +
		"exit \"$helper_exit_code\"\n"
	if err := os.WriteFile(shim, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", shimDir+string(os.PathListSeparator)+os.Getenv("PATH"))
	if err := tmuxconfig.Prepare(root); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(root, 0o700); err != nil {
		t.Fatal(err)
	}
	paths := tmuxconfig.Paths(root)
	runner := tmuxtest.NewRunnerWithConfig(t, paths.Config, paths.Enforced)
	t.Setenv("QM_TEST_SOCKET", runner.Socket())
	t.Cleanup(func() {
		cleanupPrivateServerSessions(t, root, runner)
	})
	store, err := state.NewStore(root)
	if err != nil {
		t.Fatal(err)
	}
	return store, runner
}

func cleanupPrivateServerSessions(t *testing.T, root string, runner *tmuxtest.Runner) {
	t.Helper()
	sessions, err := runner.Run(context.Background(), "list-sessions", "-F", "#{session_name}")
	if err != nil {
		if privateServerIsStopped(err) {
			return
		}
		t.Errorf("list private sessions during cleanup: %v", err)
		return
	}
	for _, id := range strings.Fields(sessions) {
		killSessionAndWaitForCleanup(t, context.Background(), runner, root, id)
	}
}

func privateServerIsStopped(err error) bool {
	var exitErr *tmux.ExitError
	if !errors.As(err, &exitErr) {
		return false
	}
	return strings.Contains(exitErr.Stderr, "no server running") ||
		strings.Contains(exitErr.Stderr, "No such file or directory")
}

func killSessionAndWaitForCleanup(t *testing.T, ctx context.Context, runner tmux.Runner, root, id string) {
	t.Helper()
	marker := cleanupHelperDonePath(root, id)
	if err := os.Remove(marker); err != nil && !os.IsNotExist(err) {
		t.Fatalf("clear prior cleanup completion marker for %s: %v", id, err)
	}
	if _, err := runner.Run(ctx, "kill-session", "-t", tmux.SessionTarget(id)); err != nil {
		t.Fatalf("kill session %s: %v", id, err)
	}
	waitForCleanupHelper(t, root, id)
}

func waitForCleanupHelper(t *testing.T, root, id string) {
	t.Helper()
	marker := cleanupHelperDonePath(root, id)
	watcher, err := fsnotify.NewWatcher()
	if err != nil {
		t.Fatalf("watch close-hook completion: %v", err)
	}
	defer watcher.Close()
	if err := watcher.Add(root); err != nil {
		t.Fatalf("watch state root for close-hook completion: %v", err)
	}
	timer := time.NewTimer(sessionIntegrationWaitTimeout)
	defer timer.Stop()
	for {
		if _, err := os.Stat(marker); err == nil {
			if data, readErr := os.ReadFile(filepath.Join(root, "helper-error")); readErr == nil {
				t.Fatalf("cleanup handler for %s: %s", id, data)
			}
			return
		} else if !os.IsNotExist(err) {
			t.Fatalf("stat close-hook completion for %s: %v", id, err)
		}
		select {
		case event, ok := <-watcher.Events:
			if !ok {
				t.Fatalf("close-hook completion watcher stopped for %s", id)
			}
			if filepath.Clean(event.Name) == marker {
				continue
			}
		case err, ok := <-watcher.Errors:
			if !ok || err != nil {
				t.Fatalf("close-hook completion watcher for %s: %v", id, err)
			}
		case <-timer.C:
			t.Fatalf("timed out after %s waiting for close-hook helper for %s to exit", sessionIntegrationWaitTimeout, id)
		}
	}
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
		killSessionAndWaitForCleanup(t, t.Context(), runner, store.Root(), id)
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
				killSessionAndWaitForCleanup(t, t.Context(), runner, store.Root(), id)
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
	for _, id := range ids {
		if _, err := os.Stat(cleanupHelperDonePath(root, id)); err != nil {
			t.Fatalf("close-hook helper for %s did not finish before runtime cleanup check: %v", id, err)
		}
		if _, err := os.Stat(state.NewRuntimeDir(root, id)); !os.IsNotExist(err) {
			t.Fatalf("runtime dir for %s still exists after close-hook helper exited (err=%v)", id, err)
		}
	}
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
	_ = receiveSessionTestValue(t, pause.paused, "Continue to reach the held tmux call")
	closed := make(chan error, 1)
	go func() { closed <- svc.SessionClosed(t.Context(), "test_named", id) }()
	close(pause.release)
	if err := receiveSessionTestValue(t, continued, "Continue to finish"); err != nil {
		t.Fatal(err)
	}
	if err := receiveSessionTestValue(t, closed, "SessionClosed to finish"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(dir); err != nil {
		t.Fatal("new incarnation's runtime dir removed", err)
	}
}
