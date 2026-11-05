package tmux

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

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
		{name: "default", server: DefaultServer(), prefix: []string{"-L", "default"}},
		{name: "socket", server: SocketServer("/tmp/qm-private/tmux.sock"), prefix: []string{"-S", "/tmp/qm-private/tmux.sock"}},
	} {
		t.Run(tt.name, func(t *testing.T) {
			calls := installFakeTmux(t)
			t.Setenv("TMUX", "/tmp/qm-elsewhere/default,4242,0")
			t.Setenv("TMUX_PANE", "%9")
			t.Setenv("TMUX_TMPDIR", "/tmp/qm-elsewhere")
			c := NewClient(tt.server)
			c.SendTimeout = 0
			ctx := t.Context()

			_, _ = c.HasSession(ctx, "qm-a")
			_ = c.NewSession(ctx, "qm-a", "work", "/tmp")
			_ = c.KillSession(ctx, "qm-a")
			_ = c.SetEnvironment(ctx, "qm-a", "K", "V")
			_ = c.UnsetEnvironment(ctx, "qm-a", "K")
			_, _, _ = c.ShowEnvironment(ctx, "qm-a", "K")
			_ = c.SetHook(ctx, "qm-a", "session-closed", "run-shell true")
			_, _ = c.ListSessions(ctx)
			_, _ = c.ListPanes(ctx, "qm-a")
			_, _ = c.Capture(ctx, PaneTarget("qm-a", 0, 0), 10)
			_ = c.Send(ctx, PaneTarget("qm-a", 0, 0), "hello")
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
	t.Setenv("TMUX", "/tmp/qm-elsewhere/default,4242,0")
	t.Setenv("TMUX_EXTRA", "kept")

	cmd := DefaultServer().Command(t.Context(), "list-sessions")

	if !slices.Contains(cmd.Env, "TMUX_EXTRA=kept") {
		t.Errorf("env dropped an unrelated variable: %q", cmd.Env)
	}
	if want := []string{"-L", "default", "list-sessions"}; !slices.Equal(cmd.Args[1:], want) {
		t.Errorf("args = %q, want tmux %q", cmd.Args, want)
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
