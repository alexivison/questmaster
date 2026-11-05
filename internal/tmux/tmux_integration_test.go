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

// A bare tmux target matches by prefix: has-session -t qm-123 finds qm-123-456.
// HasSession must report only the session it names.
func TestIntegrationHasSessionIsExact(t *testing.T) {
	t.Parallel()
	tmuxtest.RequireIntegration(t)
	runner := tmuxtest.NewRunner(t)
	mustRun(t, runner, "new-session", "-d", "-s", "qm-123-456", "sleep 60")
	client := tmux.NewClient(runner)

	assertHasSession(t, client, "qm-123", false)
	assertHasSession(t, client, "qm-123-456", true)
}

// Every call that names a session, or a pane in it, must miss a live session
// whose name only starts with that name. Each call below reached the sibling
// while targets were bare names.
func TestIntegrationSessionTargetsMissAPrefixSibling(t *testing.T) {
	t.Parallel()
	tmuxtest.RequireIntegration(t)
	runner := tmuxtest.NewRunner(t)
	const base, sibling = "qm-123", "qm-123-456"
	mustRun(t, runner, "new-session", "-d", "-s", sibling, "sleep 60")
	mustRun(t, runner, "set-environment", "-t", sibling, "MARK", "sibling")
	siblingPID := mustRun(t, runner, "display-message", "-t", sibling, "-p", "#{pane_pid}")
	client := tmux.NewClient(runner)
	client.SendTimeout = 200 * time.Millisecond
	ctx := t.Context()
	basePane := tmux.PaneTarget(base, tmux.WindowWorkspace, 0)

	if err := client.SetEnvironment(ctx, base, "MARK", "base"); err == nil {
		t.Error("SetEnvironment on a missing session succeeded")
	}
	if value, ok, err := client.ShowEnvironment(ctx, base, "MARK"); err != nil || ok {
		t.Errorf("ShowEnvironment on a missing session = %q, %v, %v; want not set", value, ok, err)
	}
	if err := client.SetHook(ctx, base, "session-closed", "run-shell true"); err == nil {
		t.Error("SetHook on a missing session succeeded")
	}
	if _, err := client.ListPanes(ctx, base); err == nil {
		t.Error("ListPanes on a missing session succeeded")
	}
	if _, err := client.Capture(ctx, basePane, 5); err == nil {
		t.Error("Capture of a missing session's pane succeeded")
	}
	if err := client.SetPaneOption(ctx, basePane, tmux.PaneRoleOption, tmux.RoleAgent); err == nil {
		t.Error("SetPaneOption on a missing session's pane succeeded")
	}
	if result := client.Send(ctx, basePane, "typed into the wrong session"); result.Submitted {
		t.Error("Send to a missing session's pane was submitted")
	}
	if err := client.RespawnPane(ctx, basePane, t.TempDir(), "sleep 60"); err == nil {
		t.Error("RespawnPane of a missing session's pane succeeded")
	}
	if err := client.KillSession(ctx, base); err != nil {
		t.Errorf("KillSession of a missing session: %v", err)
	}

	assertSessions(t, runner, sibling)
	if got := mustRun(t, runner, "show-environment", "-t", sibling, "MARK"); got != "MARK=sibling" {
		t.Errorf("sibling environment = %q, want MARK=sibling", got)
	}
	if got := mustRun(t, runner, "display-message", "-t", sibling, "-p", "#{pane_pid}|#{@party_role}"); got != siblingPID+"|" {
		t.Errorf("sibling pane pid|role = %q, want %s| (respawned or tagged)", got, siblingPID)
	}
	if got := mustRun(t, runner, "show-hooks", "-t", sibling, "session-closed"); got != "" {
		t.Errorf("sibling session-closed hook = %q, want none", got)
	}
	if got := mustRun(t, runner, "capture-pane", "-t", sibling, "-p"); strings.Contains(got, "wrong session") {
		t.Errorf("sibling pane received text: %q", got)
	}
}

// DefaultServer passes -L default. That must be the socket tmux picks when no
// flag or TMUX selects one, or sessions started before the flag became
// explicit would be out of reach.
func TestIntegrationDefaultLabelIsTheFlaglessSocket(t *testing.T) {
	t.Parallel()
	tmuxtest.RequireIntegration(t)
	// TMUX_TMPDIR moves tmux's socket directory into a private one, for raw
	// tmux only: a Server strips it.
	tmpdir := filepath.Dir(tmuxtest.NewRunner(t).Socket())
	t.Cleanup(func() {
		_, _ = runWithInheritedTMUX(context.Background(), "", tmpdir, "-L", "default", "kill-server")
	})
	if out, err := runWithInheritedTMUX(t.Context(), "", tmpdir, "new-session", "-d", "-s", "qm-flagless", "sleep 60"); err != nil {
		t.Fatalf("new-session without a flag: %v: %s", err, out)
	}
	if out, err := runWithInheritedTMUX(t.Context(), "", tmpdir, "-L", "default", "has-session", "-t", "=qm-flagless:"); err != nil {
		t.Fatalf("-L default does not see the flagless session: %v: %s", err, out)
	}
}

// An inherited TMUX names the caller's own server. A Server must still run
// every call on the server it selects.
func TestIntegrationInheritedTMUXDoesNotSteerAServer(t *testing.T) {
	tmuxtest.RequireIntegration(t)
	selected := tmuxtest.NewRunner(t)
	inherited := tmuxtest.NewRunner(t)
	mustRun(t, selected, "new-session", "-d", "-s", "qm-on-selected", "sleep 60")
	mustRun(t, inherited, "new-session", "-d", "-s", "qm-on-inherited", "sleep 60")
	inheritedPID := mustRun(t, inherited, "display-message", "-p", "#{pid}")
	t.Setenv("TMUX", fmt.Sprintf("%s,%s,0", inherited.Socket(), inheritedPID))
	t.Setenv("TMUX_PANE", mustRun(t, inherited, "display-message", "-t", "qm-on-inherited", "-p", "#{pane_id}"))
	client := tmux.NewClient(tmux.SocketServer(selected.Socket()))
	ctx := t.Context()

	assertHasSession(t, client, "qm-on-inherited", false)
	if err := client.NewSession(ctx, "qm-created", "", t.TempDir()); err != nil {
		t.Fatalf("NewSession: %v", err)
	}
	if err := client.SetEnvironment(ctx, "qm-created", "MARK", "selected"); err != nil {
		t.Fatalf("SetEnvironment: %v", err)
	}
	if err := client.KillSession(ctx, "qm-on-inherited"); err != nil {
		t.Fatalf("KillSession: %v", err)
	}

	assertSessions(t, selected, "qm-on-selected", "qm-created")
	assertSessions(t, inherited, "qm-on-inherited")
	if got := mustRun(t, selected, "show-environment", "-t", "qm-created", "MARK"); got != "MARK=selected" {
		t.Errorf("MARK on the selected server = %q", got)
	}
}

// Commands run without the caller's TMUX_PANE, so tmux cannot tell which client
// is the caller's. SwitchClient finds it from the caller's pane: the client
// showing that pane's session. A pane on another server has none.
func TestIntegrationSwitchClientMovesTheCallersClient(t *testing.T) {
	tmuxtest.RequireIntegration(t)
	runner := tmuxtest.NewRunner(t)
	mustRun(t, runner, "new-session", "-d", "-s", "qm-from", "sleep 60")
	mustRun(t, runner, "new-session", "-d", "-s", "qm-other", "sleep 60")
	mustRun(t, runner, "new-session", "-d", "-s", "qm-to", "sleep 60")
	startControlClient(t, runner, "qm-other")
	caller := startControlClient(t, runner, "qm-from")
	serverPID := mustRun(t, runner, "display-message", "-p", "#{pid}")
	callerPane := mustRun(t, runner, "display-message", "-t", "qm-from", "-p", "#{pane_id}")
	client := tmux.NewClient(runner)
	ctx := t.Context()

	t.Run("on another server", func(t *testing.T) {
		t.Setenv("TMUX", fmt.Sprintf("%s,%s,0", filepath.Join(t.TempDir(), "other.sock"), serverPID))
		t.Setenv("TMUX_PANE", callerPane)
		if err := client.SwitchClient(ctx, "qm-to"); err == nil {
			t.Fatal("SwitchClient succeeded for a pane on another server")
		}
		assertClientSessions(t, runner, "qm-from", "qm-other")
	})

	t.Run("on this server", func(t *testing.T) {
		t.Setenv("TMUX", fmt.Sprintf("%s,%s,0", runner.Socket(), serverPID))
		t.Setenv("TMUX_PANE", callerPane)
		if err := client.SwitchClient(ctx, "qm-to"); err != nil {
			t.Fatalf("SwitchClient: %v", err)
		}
		if got := mustRun(t, runner, "display-message", "-c", caller, "-p", "#{client_session}"); got != "qm-to" {
			t.Errorf("caller's client shows %s, want qm-to", got)
		}
		assertClientSessions(t, runner, "qm-other", "qm-to")
	})
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

// startControlClient attaches a control-mode client to session and returns its
// name. The client stays attached until the test ends.
func startControlClient(t *testing.T, runner *tmuxtest.Runner, session string) string {
	t.Helper()
	before := strings.Fields(mustRun(t, runner, "list-clients", "-F", "#{client_name}"))
	cmd := exec.Command("tmux", "-S", runner.Socket(), "-C", "attach-session", "-t", "="+session+":")
	cmd.Env = []string{"PATH=" + os.Getenv("PATH"), "HOME=" + os.Getenv("HOME")}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatalf("start control client: %v", err)
	}
	t.Cleanup(func() {
		_ = stdin.Close()
		_ = cmd.Wait()
	})
	deadline := time.Now().Add(serverExitTimeout)
	for {
		for _, name := range strings.Fields(mustRun(t, runner, "list-clients", "-F", "#{client_name}")) {
			if !slices.Contains(before, name) {
				return name
			}
		}
		if time.Now().After(deadline) {
			t.Fatalf("control client on %s never attached", session)
		}
		time.Sleep(serverExitPoll)
	}
}

// assertClientSessions checks which sessions the server's clients show.
func assertClientSessions(t *testing.T, runner *tmuxtest.Runner, want ...string) {
	t.Helper()
	got := strings.Fields(mustRun(t, runner, "list-clients", "-F", "#{client_session}"))
	slices.Sort(got)
	slices.Sort(want)
	if !slices.Equal(got, want) {
		t.Fatalf("client sessions = %q, want %q", got, want)
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
