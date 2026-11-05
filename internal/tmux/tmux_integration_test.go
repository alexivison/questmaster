package tmux_test

// Integration tests run real tmux, but only on private sockets (tmuxtest.NewRunner,
// or a -L label under its directory), and only when QUESTMASTER_TMUX_INTEGRATION=1.
//
// This file is package tmux_test because it imports tmuxtest, which imports
// internal/tmux; the package-internal tests cannot import it without a cycle.

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmux/tmuxtest"
)

const (
	serverExitTimeout = 5 * time.Second
	serverExitPoll    = 50 * time.Millisecond
)

func TestIntegrationPrivateServerRoundTrip(t *testing.T) {
	t.Parallel()
	tmuxtest.RequireIntegration(t)
	client := tmux.NewClient(tmuxtest.NewRunner(t))
	ctx := t.Context()
	const name = "qm-roundtrip"

	if err := client.NewSession(ctx, name, "work", t.TempDir()); err != nil {
		t.Fatalf("NewSession: %v", err)
	}
	assertHasSession(t, client, name, true)
	if err := client.KillSession(ctx, name); err != nil {
		t.Fatalf("KillSession: %v", err)
	}
	assertHasSession(t, client, name, false)
}

func TestIntegrationPrivateServerIsStoppedOnCleanup(t *testing.T) {
	t.Parallel()
	tmuxtest.RequireIntegration(t)
	var serverPID string

	// The subtest's cleanup kills its server before t.Run returns.
	t.Run("server", func(t *testing.T) {
		runner := tmuxtest.NewRunner(t)
		if _, err := runner.Run(t.Context(), "new-session", "-d", "-s", "qm-cleanup", "sleep 60"); err != nil {
			t.Fatalf("new-session: %v", err)
		}
		pid, err := runner.Run(t.Context(), "display-message", "-p", "#{pid}")
		if err != nil {
			t.Fatalf("display-message: %v", err)
		}
		serverPID = pid
	})

	waitForServerExit(t, serverPID)
}

// TestIntegrationExplicitSelectorOverridesInheritedTMUX settles open question 7:
// on the installed tmux, an explicit -S or -L wins over an inherited TMUX.
// TMUX here names a second private server, so a command that followed TMUX
// would land there and the assertions would fail.
func TestIntegrationExplicitSelectorOverridesInheritedTMUX(t *testing.T) {
	t.Parallel()
	tmuxtest.RequireIntegration(t)
	target := tmuxtest.NewRunner(t)
	inherited := tmuxtest.NewRunner(t)
	mustRun(t, inherited, "new-session", "-d", "-s", "on_inherited", "sleep 60")
	inheritedPID := mustRun(t, inherited, "display-message", "-p", "#{pid}")
	inheritedTMUX := fmt.Sprintf("%s,%s,0", inherited.Socket(), inheritedPID)
	mustRun(t, target, "new-session", "-d", "-s", "on_target", "sleep 60")

	t.Run("explicit -S", func(t *testing.T) {
		if out, err := runWithInheritedTMUX(t.Context(), inheritedTMUX, "", "-S", target.Socket(), "new-session", "-d", "-s", "marker_socket", "sleep 60"); err != nil {
			t.Fatalf("new-session -S with inherited TMUX: %v: %s", err, out)
		}
		assertSessions(t, target, "on_target", "marker_socket")
		assertSessions(t, inherited, "on_inherited")
	})

	t.Run("explicit -L", func(t *testing.T) {
		const label = "qmlabel"
		// -L sockets live under TMUX_TMPDIR, which the target's private dir
		// holds, so this server is private too.
		tmpdir := filepath.Dir(target.Socket())
		t.Cleanup(func() {
			_, _ = runWithInheritedTMUX(context.Background(), inheritedTMUX, tmpdir, "-L", label, "kill-server")
		})
		if out, err := runWithInheritedTMUX(t.Context(), inheritedTMUX, tmpdir, "-L", label, "new-session", "-d", "-s", "marker_label", "sleep 60"); err != nil {
			t.Fatalf("new-session -L with inherited TMUX: %v: %s", err, out)
		}
		out, err := runWithInheritedTMUX(t.Context(), inheritedTMUX, tmpdir, "-L", label, "list-sessions", "-F", "#{session_name}")
		if err != nil {
			t.Fatalf("list-sessions -L: %v: %s", err, out)
		}
		if !strings.Contains(out, "marker_label") {
			t.Fatalf("-L server sessions = %q, want marker_label", out)
		}
		assertSessions(t, inherited, "on_inherited")
	})
}

func TestIntegrationSetManagedPaneTitleDisplaysZero(t *testing.T) {
	t.Parallel()
	tmuxtest.RequireIntegration(t)
	runner := tmuxtest.NewRunner(t)
	mustRun(t, runner, "new-session", "-d", "-s", "qm-title-zero", "sleep 60")
	mustRun(t, runner, "set-option", "-wg", "pane-border-format", "#{pane_title}")
	client := tmux.NewClient(runner)
	if err := client.SetManagedPaneTitle(t.Context(), "qm-title-zero:0.0", "0"); err != nil {
		t.Fatal(err)
	}
	if err := client.SelectPaneTitle(t.Context(), "qm-title-zero:0.0", "Native"); err != nil {
		t.Fatal(err)
	}
	visible := mustRun(t, runner, "display-message", "-t", "qm-title-zero:0.0", "-p", "#{E:#{pane-border-format}}")
	if visible != "0" {
		t.Fatalf("pane border title = %q, want Questmaster title 0", visible)
	}
}

func TestIntegrationSetManagedPaneTitleOverridesPaneLocalFormat(t *testing.T) {
	t.Parallel()
	tmuxtest.RequireIntegration(t)
	runner := tmuxtest.NewRunner(t)
	mustRun(t, runner, "new-session", "-d", "-s", "qm-title-local", "sleep 60")
	const target = "qm-title-local:0.0"
	if _, err := runner.Run(t.Context(), "set-option", "-p", "-t", target, "pane-border-format", "#{pane_title}"); err != nil {
		t.Skipf("tmux does not support pane-local border formats: %v", err)
	}
	client := tmux.NewClient(runner)
	if err := client.SetManagedPaneTitle(t.Context(), target, "Questmaster"); err != nil {
		t.Fatal(err)
	}
	if err := client.SelectPaneTitle(t.Context(), target, "Native"); err != nil {
		t.Fatal(err)
	}
	visible := mustRun(t, runner, "display-message", "-t", target, "-p", "#{E:#{pane-border-format}}")
	if visible != "Questmaster" {
		t.Fatalf("pane border title = %q, want Questmaster title", visible)
	}
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

// A tmux server whose own working directory has been deleted starts every new pane
// there and ignores -c. RespawnPane must still land the command in its directory.
func TestIntegrationRespawnPaneSurvivesADeletedServerDirectory(t *testing.T) {
	tmuxtest.RequireIntegration(t)
	serverDir := t.TempDir()
	t.Chdir(serverDir) // the server takes the directory of the client that starts it
	runner := tmuxtest.NewRunner(t)
	client := tmux.NewClient(runner)
	ctx := t.Context()
	if err := client.NewSession(ctx, "qm-server-start", "", serverDir); err != nil {
		t.Fatalf("NewSession: %v", err)
	}
	t.Chdir(t.TempDir())
	if err := os.RemoveAll(serverDir); err != nil {
		t.Fatalf("remove server directory: %v", err)
	}

	workDir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	out := filepath.Join(workDir, "pwd.out")
	const name = "qm-after-delete"
	if err := client.NewSession(ctx, name, "", workDir); err != nil {
		t.Fatalf("NewSession: %v", err)
	}
	if err := client.RespawnPane(ctx, "="+name+":", workDir, fmt.Sprintf("pwd -P > %q; sleep 30", out)); err != nil {
		t.Fatalf("RespawnPane: %v", err)
	}

	deadline := time.Now().Add(serverExitTimeout)
	for {
		data, err := os.ReadFile(out)
		if err == nil && strings.TrimSpace(string(data)) != "" {
			if got := strings.TrimSpace(string(data)); got != workDir {
				t.Fatalf("pane started in %q, want %q", got, workDir)
			}
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("pane never wrote its directory to %s (read err %v); it likely started in the deleted server directory", out, err)
		}
		time.Sleep(serverExitPoll)
	}
}

func mustRun(t *testing.T, runner *tmuxtest.Runner, args ...string) string {
	t.Helper()
	out, err := runner.Run(t.Context(), args...)
	if err != nil {
		t.Fatalf("tmux %v: %v", args, err)
	}
	return out
}

func assertHasSession(t *testing.T, client *tmux.Client, name string, want bool) {
	t.Helper()
	got, err := client.HasSession(t.Context(), name)
	if err != nil {
		t.Fatalf("HasSession(%s): %v", name, err)
	}
	if got != want {
		t.Fatalf("HasSession(%s) = %v, want %v", name, got, want)
	}
}

// assertSessions checks that the server holds exactly the named sessions.
func assertSessions(t *testing.T, runner *tmuxtest.Runner, want ...string) {
	t.Helper()
	out := mustRun(t, runner, "list-sessions", "-F", "#{session_name}")
	got := strings.Fields(out)
	slices.Sort(got)
	slices.Sort(want)
	if !slices.Equal(got, want) {
		t.Fatalf("sessions = %q, want %q", got, want)
	}
}

// runWithInheritedTMUX runs tmux with TMUX set to inherited, as a shell started
// inside another tmux session would have it. A non-empty tmuxTmpdir sets
// TMUX_TMPDIR, which is where -L sockets live. Callers name every server with
// -S or -L, so inherited is the only thing that could point somewhere else.
func runWithInheritedTMUX(ctx context.Context, inherited, tmuxTmpdir string, args ...string) (string, error) {
	env := []string{"TMUX=" + inherited}
	for _, kv := range os.Environ() {
		if strings.HasPrefix(kv, "TMUX=") || strings.HasPrefix(kv, "TMUX_PANE=") || strings.HasPrefix(kv, "TMUX_TMPDIR=") {
			continue
		}
		env = append(env, kv)
	}
	if tmuxTmpdir != "" {
		env = append(env, "TMUX_TMPDIR="+tmuxTmpdir)
	}
	cmd := exec.CommandContext(ctx, "tmux", args...)
	cmd.Env = env
	out, err := cmd.CombinedOutput()
	return strings.TrimSpace(string(out)), err
}

// waitForServerExit polls until the server pid has stopped. A zombie counts as
// stopped: the test needs the server to exit, not to be reaped.
func waitForServerExit(t *testing.T, pid string) {
	t.Helper()
	deadline := time.Now().Add(serverExitTimeout)
	for {
		stopped, err := serverStopped(t.Context(), pid)
		if err != nil {
			t.Fatalf("check server pid %s: %v", pid, err)
		}
		if stopped {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("server pid %s still running after cleanup", pid)
		}
		time.Sleep(serverExitPoll)
	}
}

func serverStopped(ctx context.Context, pid string) (bool, error) {
	out, err := exec.CommandContext(ctx, "ps", "-o", "stat=", "-p", pid).Output()
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		// ps exits non-zero when the pid no longer exists.
		return true, nil
	}
	if err != nil {
		return false, err
	}
	stat := strings.TrimSpace(string(out))
	return stat == "" || strings.HasPrefix(stat, "Z"), nil
}
