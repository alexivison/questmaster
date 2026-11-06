package tmux

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestServerRunDoesNotWaitForDetachedChildOutput(t *testing.T) {
	bin := t.TempDir()
	childPID := filepath.Join(t.TempDir(), "child.pid")
	t.Setenv("QM_TEST_CHILD_PID", childPID)
	t.Cleanup(func() { stopFakeTmuxChild(t, childPID) })
	script := "#!/bin/sh\nprintf 'ready\\n'\nsleep 30 & echo $! > \"$QM_TEST_CHILD_PID\"\n"
	if err := os.WriteFile(filepath.Join(bin, "tmux"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()
	started := time.Now()
	out, err := SocketServer("/tmp/qm-private/tmux.sock").Run(ctx, "list-sessions")
	if err != nil || out != "ready" || time.Since(started) > 10*time.Second {
		t.Fatalf("Run waited for a detached child: output=%q error=%v elapsed=%s", out, err, time.Since(started))
	}
}

func stopFakeTmuxChild(t *testing.T, pidFile string) {
	t.Helper()
	data, err := os.ReadFile(pidFile)
	if os.IsNotExist(err) {
		return
	}
	if err != nil {
		t.Errorf("read fake tmux child PID: %v", err)
		return
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil {
		t.Errorf("parse fake tmux child PID: %v", err)
		return
	}
	process, err := os.FindProcess(pid)
	if err != nil {
		t.Errorf("find fake tmux child: %v", err)
		return
	}
	if err := process.Kill(); err != nil && !os.IsNotExist(err) {
		t.Errorf("kill fake tmux child: %v", err)
	}
	_ = process.Release()
}

// fakeTmuxScript stands in for tmux on PATH. Each run writes one file: the
// routing variables it inherited, then its arguments, one per line. It starts
// no server and prints nothing.
const fakeTmuxScript = `#!/bin/sh
out=$(mktemp "$QM_FAKE_TMUX_LOG/call.XXXXXX")
{
	printf 'TMUX=%s|TMUX_PANE=%s|TMUX_TMPDIR=%s\n' "${TMUX-unset}" "${TMUX_PANE-unset}" "${TMUX_TMPDIR-unset}"
	for arg in "$@"; do printf '%s\n' "$arg"; done
} > "$out"
`

type fakeTmuxCall struct {
	env  string
	args []string
}

// installFakeTmux puts fakeTmuxScript first on PATH and returns a reader for
// the calls it recorded.
func installFakeTmux(t *testing.T) func() []fakeTmuxCall {
	t.Helper()
	bin := t.TempDir()
	logDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(bin, "tmux"), []byte(fakeTmuxScript), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("QM_FAKE_TMUX_LOG", logDir)
	return func() []fakeTmuxCall {
		t.Helper()
		files, err := filepath.Glob(filepath.Join(logDir, "call.*"))
		if err != nil {
			t.Fatal(err)
		}
		calls := make([]fakeTmuxCall, 0, len(files))
		for _, file := range files {
			data, err := os.ReadFile(file)
			if err != nil {
				t.Fatal(err)
			}
			lines := strings.Split(strings.TrimSuffix(string(data), "\n"), "\n")
			calls = append(calls, fakeTmuxCall{env: lines[0], args: lines[1:]})
		}
		return calls
	}
}

// Every command a Client sends names the selected server first, and none
// carries the caller's TMUX, TMUX_PANE or TMUX_TMPDIR: tmux follows TMUX to
// the caller's server whenever no flag names one.
func TestServerRunsEveryCommandOnItsSelection(t *testing.T) {
	for _, tt := range []struct {
		name   string
		server Server
		prefix []string
	}{
		{name: "socket", server: SocketServer("/tmp/qm-private/tmux.sock"), prefix: []string{"-S", "/tmp/qm-private/tmux.sock"}},
	} {
		t.Run(tt.name, func(t *testing.T) {
			calls := installFakeTmux(t)
			t.Setenv("TMUX", "/tmp/qm-elsewhere/default,4242,0")
			t.Setenv("TMUX_PANE", "%9")
			t.Setenv("TMUX_TMPDIR", "/tmp/qm-elsewhere")
			c := NewClient(tt.server)
			c.SendTimeout = time.Second
			ctx := t.Context()

			_, _ = c.HasSession(ctx, "qm-a")
			_, _ = c.NewSession(ctx, "qm-a", "work", "/tmp")
			_ = c.KillSession(ctx, "qm-a")
			_ = c.SetEnvironment(ctx, "qm-a", "K", "V")
			_ = c.UnsetEnvironment(ctx, "qm-a", "K")
			_, _, _ = c.ShowEnvironment(ctx, "qm-a", "K")
			_ = c.SetHook(ctx, "qm-a", "session-closed", "run-shell true")
			_, _ = c.ListSessions(ctx)
			_, _ = c.ListPanes(ctx, "qm-a")
			_, _ = c.Capture(ctx, PaneTarget("qm-a", 0, 0), 10)
			_ = c.Send(ctx, t.TempDir(), PaneTarget("qm-a", 0, 0), "hello")
			_ = c.RespawnPane(ctx, PaneTarget("qm-a", 0, 0), "/tmp", "sh")
			_ = c.SwitchClient(ctx, "qm-a")
			_, _ = c.SessionName(ctx)

			recorded := calls()
			if len(recorded) < 10 {
				t.Fatalf("recorded %d tmux calls, want at least 10", len(recorded))
			}
			for _, call := range recorded {
				if len(call.args) < len(tt.prefix) || !slices.Equal(call.args[:len(tt.prefix)], tt.prefix) {
					t.Errorf("tmux %q does not start with %q", call.args, tt.prefix)
				}
				if call.env != "TMUX=unset|TMUX_PANE=unset|TMUX_TMPDIR=unset" {
					t.Errorf("tmux %q inherited %s", call.args, call.env)
				}
			}
		})
	}
}

func TestServerCommandKeepsTheRestOfTheEnvironment(t *testing.T) {
	t.Setenv("QUESTMASTER_TMUX_LABEL", "questmaster")
	t.Setenv("TMUX", "/tmp/qm-elsewhere/default,4242,0")
	t.Setenv("TMUX_EXTRA", "kept")

	cmd := DefaultServer("/tmp/user.conf", "/tmp/enforced.conf").Command(t.Context(), "list-sessions")

	if !slices.Contains(cmd.Env, "TMUX_EXTRA=kept") {
		t.Errorf("env dropped an unrelated variable: %q", cmd.Env)
	}
	if want := []string{"-L", "questmaster", "-f", "/tmp/user.conf", "-f", "/tmp/enforced.conf", "list-sessions"}; !slices.Equal(cmd.Args[1:], want) {
		t.Errorf("args = %q, want tmux %q", cmd.Args, want)
	}
}

func TestDefaultServerIsNamed(t *testing.T) {
	t.Setenv("QUESTMASTER_TMUX_LABEL", "dev_test")
	if got := DefaultServer("/tmp/user.conf", "/tmp/enforced.conf").Command(t.Context(), "list-sessions").Args[1:3]; !slices.Equal(got, []string{"-L", "dev_test"}) {
		t.Fatalf("creation selector = %q", got)
	}
	if err := os.Unsetenv("QUESTMASTER_TMUX_LABEL"); err != nil {
		t.Fatal(err)
	}
	if got := DefaultServer("/tmp/user.conf", "/tmp/enforced.conf").Command(t.Context(), "list-sessions").Args[1:3]; !slices.Equal(got, []string{"-L", "questmaster"}) {
		t.Fatalf("unset creation selector = %q", got)
	}
}

func TestServerEnvDropsOnlyTheRoutingVariables(t *testing.T) {
	t.Parallel()
	environ := []string{"TMUX=a", "TMUX_PANE=b", "TMUX_TMPDIR=c", "TMUX_EXTRA=keep", "PATH=/bin", "NOEQUALS"}

	got := serverEnv(environ)

	if want := []string{"TMUX_EXTRA=keep", "PATH=/bin", "NOEQUALS"}; !slices.Equal(got, want) {
		t.Fatalf("serverEnv = %q, want %q", got, want)
	}
}

func TestNamedServerArgsAndEnv(t *testing.T) {
	t.Setenv("QUESTMASTER_TMUX_LABEL", "questmaster")
	named, err := NamedServer("/tmp/user.conf", "/tmp/enforced.conf")
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("TMUX", "hostile")
	t.Setenv("TMUX_PANE", "%1")
	t.Setenv("TMUX_TMPDIR", "/tmp/hostile")
	t.Setenv("QUESTMASTER_SESSION", "qm-hostile")
	t.Setenv("QUESTMASTER_TMUX_SERVER", "hostile")
	t.Setenv("QUESTMASTER_RUNTIME_DIR", "/tmp/hostile")
	t.Setenv("QM_KEEP", "yes")
	for _, tc := range []struct {
		name   string
		server Server
		want   []string
	}{
		{"named", named, []string{"-L", "questmaster", "-f", "/tmp/user.conf", "-f", "/tmp/enforced.conf", "list-sessions"}},
		{"default", DefaultServer("/tmp/user.conf", "/tmp/enforced.conf"), []string{"-L", "questmaster", "-f", "/tmp/user.conf", "-f", "/tmp/enforced.conf", "list-sessions"}},
	} {
		cmd := tc.server.Command(t.Context(), "list-sessions")
		if !slices.Equal(cmd.Args[1:], tc.want) {
			t.Errorf("%s args = %q, want %q", tc.name, cmd.Args[1:], tc.want)
		}
		if cmd.Dir != "/" {
			t.Errorf("%s Dir = %q", tc.name, cmd.Dir)
		}
		for _, key := range []string{"TMUX", "TMUX_PANE", "TMUX_TMPDIR", "QUESTMASTER_SESSION", "QUESTMASTER_TMUX_SERVER", "QUESTMASTER_RUNTIME_DIR", "QUESTMASTER_TMUX_LABEL"} {
			for _, kv := range cmd.Env {
				if strings.HasPrefix(kv, key+"=") {
					t.Errorf("%s inherited %s", tc.name, key)
				}
			}
		}
		if !slices.Contains(cmd.Env, "QM_KEEP=yes") {
			t.Errorf("%s dropped unrelated env", tc.name)
		}
	}
}

func TestNamedServerLabelOverride(t *testing.T) {
	t.Setenv("QUESTMASTER_TMUX_LABEL", "dev_1")
	server, err := NamedServer("/tmp/user.conf", "/tmp/enforced.conf")
	if err != nil {
		t.Fatal(err)
	}
	if got := server.Command(t.Context(), "list-sessions").Args[1:3]; !slices.Equal(got, []string{"-L", "dev_1"}) {
		t.Fatalf("selector = %q", got)
	}
	if err := os.Unsetenv("QUESTMASTER_TMUX_LABEL"); err != nil {
		t.Fatal(err)
	}
	server, err = NamedServer("/tmp/user.conf", "/tmp/enforced.conf")
	if err != nil {
		t.Fatal(err)
	}
	if got := server.Command(t.Context(), "list-sessions").Args[1:3]; !slices.Equal(got, []string{"-L", "questmaster"}) {
		t.Fatalf("default selector = %q", got)
	}
}

func TestNamedServerLabelIgnoresEnvironment(t *testing.T) {
	t.Setenv("QUESTMASTER_TMUX_LABEL", "dev_current")
	server, err := NamedServerLabel("dev_recorded", "/tmp/user.conf", "/tmp/enforced.conf")
	if err != nil {
		t.Fatal(err)
	}
	if got := server.Label(); got != "dev_recorded" {
		t.Fatalf("label = %q", got)
	}
	for _, invalid := range []string{"", "default", "Bad", "with space", "123456789012345678901234567890123"} {
		if _, err := NamedServerLabel(invalid, "/tmp/user.conf", "/tmp/enforced.conf"); err == nil {
			t.Fatalf("accepted %q", invalid)
		}
	}
}

func TestNamedServerRejectsInvalidLabel(t *testing.T) {
	for _, label := range []string{"", "default", "Upper", strings.Repeat("a", 33), "a/b", "has space"} {
		t.Run(label, func(t *testing.T) {
			t.Setenv("QUESTMASTER_TMUX_LABEL", label)
			if _, err := NamedServer("/tmp/user.conf", "/tmp/enforced.conf"); err == nil {
				t.Fatalf("accepted label %q", label)
			}
		})
	}
}
