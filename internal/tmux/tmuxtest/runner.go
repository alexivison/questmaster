// Package tmuxtest runs tmux for tests on private sockets. Every server call
// names its socket with -S, the child environment drops the variables that
// route tmux to another server, and RequireIntegration gates the tests that
// start real tmux.
//
// Production code must not import this package. A test in this package fails
// if any non-test file does.
package tmuxtest

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/tmux"
)

const (
	// integrationEnv gates the tests that start real tmux.
	integrationEnv = "QUESTMASTER_TMUX_INTEGRATION"

	// sunPathSize is sockaddr_un.sun_path on macOS, NUL terminator included.
	// Linux allows 108; the stricter limit applies everywhere.
	sunPathSize = 104
	// maxSocketPathBytes is the longest socket path the harness accepts.
	maxSocketPathBytes = sunPathSize - 1
	commandTimeout     = 10 * time.Second
)

// errNoSocket reports a tmux call that is not addressed to a private socket.
var errNoSocket = errors.New("tmuxtest: tmux call without -S <socket>; refusing to reach the default server")

// Runner runs tmux commands on one private server socket. It satisfies tmux.Runner.
type Runner struct {
	socket      string
	configFiles []string
}

// NewRunner returns a Runner on a fresh private socket. On cleanup it kills the
// server and removes the socket directory.
func NewRunner(t testing.TB) *Runner {
	return NewRunnerWithConfig(t)
}

// NewRunnerWithConfig starts a private server with the given config files in
// order. Every tmux call still names the private -S socket explicitly.
func NewRunnerWithConfig(t testing.TB, files ...string) *Runner {
	t.Helper()
	// Not t.TempDir: its path carries the test name and can exceed the socket limit.
	dir, err := os.MkdirTemp("", "qmt")
	if err != nil {
		t.Fatalf("create socket directory: %v", err)
	}
	socket := filepath.Join(dir, "tmux.sock")
	t.Cleanup(func() {
		stopServer(t, socket)
		_ = os.RemoveAll(dir)
	})
	if err := checkSocketPath(socket, os.Getuid()); err != nil {
		t.Fatal(err)
	}
	return &Runner{socket: socket, configFiles: append([]string(nil), files...)}
}

// Socket returns the private socket path.
func (r *Runner) Socket() string {
	return r.socket
}

// Run runs one tmux command on the runner's socket. args must not select a
// server: a leading -S or -L would override the socket this Runner adds.
func (r *Runner) Run(ctx context.Context, args ...string) (string, error) {
	if len(args) > 0 && isServerSelector(args[0]) {
		return "", fmt.Errorf("tmuxtest: %s in the command position would select another server", args[0])
	}
	argv := []string{"-S", r.socket}
	for _, file := range r.configFiles {
		argv = append(argv, "-f", file)
	}
	return runTmux(ctx, r.socket, append(argv, args...))
}

// RequireIntegration skips t unless QUESTMASTER_TMUX_INTEGRATION=1. With the
// flag set it logs `tmux -V` and fails if tmux is missing. With the flag unset
// it starts no process.
func RequireIntegration(t testing.TB) {
	t.Helper()
	if os.Getenv(integrationEnv) != "1" {
		t.Skipf("set %s=1 to run tmux integration tests", integrationEnv)
	}
	version, err := tmuxVersion()
	if err != nil {
		t.Fatalf("tmux -V (integration tests need tmux on PATH): %v", err)
	}
	t.Logf("tmux -V: %s", version)
}

// runTmux runs tmux with argv, which must begin with -S <socket>. It is the one
// place this package starts tmux against a server.
func runTmux(ctx context.Context, socket string, argv []string) (string, error) {
	if len(argv) < 2 || argv[0] != "-S" || argv[1] != socket {
		return "", fmt.Errorf("%w: %q", errNoSocket, argv)
	}
	ctx, cancel := context.WithTimeout(ctx, commandTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "tmux", argv...)
	cmd.Env = childEnv(os.Environ())
	out, err := cmd.Output()
	if err != nil {
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return "", fmt.Errorf("tmux %q timed out: %w", argv[2:], ctx.Err())
		}
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			return "", &tmux.ExitError{
				Code:   exitErr.ExitCode(),
				Stderr: strings.TrimRight(string(exitErr.Stderr), "\n"),
			}
		}
		return "", fmt.Errorf("run tmux: %w", err)
	}
	return strings.TrimRight(string(out), "\n"), nil
}

// stopServer kills the server on socket. A server that never started is fine.
// The context is Background because t's context is already cancelled when
// cleanups run.
func stopServer(t testing.TB, socket string) {
	t.Helper()
	_, err := runTmux(context.Background(), socket, []string{"-S", socket, "kill-server"})
	if err != nil && !isNoServer(err) {
		t.Errorf("kill private tmux server %s: %v", socket, err)
	}
}

func isNoServer(err error) bool {
	var exitErr *tmux.ExitError
	if !errors.As(err, &exitErr) {
		return false
	}
	return strings.Contains(exitErr.Stderr, "no server running") ||
		strings.Contains(exitErr.Stderr, "No such file or directory")
}

// tmuxVersion runs `tmux -V`. It names no server and never connects to one.
func tmuxVersion() (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), commandTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "tmux", "-V")
	cmd.Env = childEnv(os.Environ())
	out, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("run tmux -V: %w", err)
	}
	return strings.TrimSpace(string(out)), nil
}

func isServerSelector(arg string) bool {
	return arg == "-S" || arg == "-L"
}

// childEnv drops the variables that route a tmux client to another server or
// socket directory. The explicit -S is what picks the server, so these must
// not win.
func childEnv(environ []string) []string {
	env := make([]string, 0, len(environ))
	for _, kv := range environ {
		if !isRoutingVar(kv) {
			env = append(env, kv)
		}
	}
	return env
}

func isRoutingVar(kv string) bool {
	key, _, _ := strings.Cut(kv, "=")
	switch key {
	case "TMUX", "TMUX_PANE", "TMUX_TMPDIR":
		return true
	}
	return false
}

// checkSocketPath refuses a socket path that is too long for sun_path, or that
// lies inside tmux's default directory for uid. Children run without
// TMUX_TMPDIR, so that directory is /tmp/tmux-<uid> (macOS also resolves it
// under /private/tmp).
func checkSocketPath(socket string, uid int) error {
	if len(socket) > maxSocketPathBytes {
		return fmt.Errorf("socket path is %d bytes, over the %d-byte limit: %s", len(socket), maxSocketPathBytes, socket)
	}
	for _, tmpRoot := range []string{"/tmp", "/private/tmp"} {
		defaultDir := filepath.Join(tmpRoot, fmt.Sprintf("tmux-%d", uid))
		if strings.HasPrefix(socket, defaultDir+string(filepath.Separator)) {
			return fmt.Errorf("socket %s is inside tmux's default directory %s", socket, defaultDir)
		}
	}
	return nil
}
