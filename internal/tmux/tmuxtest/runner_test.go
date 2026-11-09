package tmuxtest

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

// fakeTmux puts a stub named tmux first on PATH. The stub records its argv and
// environment in the returned directory, so these tests see what the harness
// would run without starting tmux. Its `-V` answer is fixed.
func fakeTmux(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	bin := filepath.Join(dir, "bin")
	if err := os.Mkdir(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	stub := `#!/bin/sh
printf '%s\n' "$@" > "$QMTEST_STUB_DIR/argv"
if [ "$1" = "-V" ]; then echo "tmux 0.0-stub"; exit 0; fi
env > "$QMTEST_STUB_DIR/env"
`
	if err := os.WriteFile(filepath.Join(bin, "tmux"), []byte(stub), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("QMTEST_STUB_DIR", dir)
	return dir
}

func TestRunnerHonorsCallerDeadline(t *testing.T) {
	dir := fakeTmux(t)
	if err := os.WriteFile(filepath.Join(dir, "bin", "tmux"), []byte("#!/bin/sh\nexec sleep 60\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	r := &Runner{socket: "/tmp/qmt-short/tmux.sock"}
	ctx, cancel := context.WithTimeout(t.Context(), 100*time.Millisecond)
	defer cancel()
	if _, err := r.Run(ctx, "list-sessions"); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("Run error = %v, want deadline exceeded", err)
	}
}

func stubRan(dir string) bool {
	_, err := os.Stat(filepath.Join(dir, "argv"))
	return err == nil
}

func readLines(t *testing.T, path string) []string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return strings.Split(strings.TrimSuffix(string(data), "\n"), "\n")
}

func TestRunTmuxRefusesCallWithoutSocketFlag(t *testing.T) {
	dir := fakeTmux(t)
	const socket = "/tmp/qmt-short/tmux.sock"

	tests := map[string][]string{
		"bare command":      {"list-sessions"},
		"other label":       {"-L", "default", "list-sessions"},
		"socket after verb": {"list-sessions", "-S", socket},
		"other socket path": {"-S", "/tmp/other.sock", "list-sessions"},
	}
	for name, argv := range tests {
		t.Run(name, func(t *testing.T) {
			_, err := runTmux(t.Context(), socket, argv)
			if !errors.Is(err, errNoSocket) {
				t.Fatalf("runTmux(%q) error = %v, want errNoSocket", argv, err)
			}
		})
	}
	if stubRan(dir) {
		t.Fatal("tmux was started for a call without -S <socket>")
	}
}

func TestRunnerAddsSocketAndStripsTmuxEnvironment(t *testing.T) {
	dir := fakeTmux(t)
	t.Setenv("TMUX", "/tmp/outer.sock,1,0")
	t.Setenv("TMUX_PANE", "%1")
	t.Setenv("TMUX_TMPDIR", "/tmp/outer-tmpdir")
	r := &Runner{socket: "/tmp/qmt-short/tmux.sock"}

	if _, err := r.Run(t.Context(), "list-sessions", "-F", "#{session_name}"); err != nil {
		t.Fatalf("Run: %v", err)
	}

	wantArgv := []string{"-S", r.socket, "list-sessions", "-F", "#{session_name}"}
	if got := readLines(t, filepath.Join(dir, "argv")); !reflect.DeepEqual(got, wantArgv) {
		t.Fatalf("argv = %q, want %q", got, wantArgv)
	}
	env := readLines(t, filepath.Join(dir, "env"))
	for _, key := range []string{"TMUX=", "TMUX_PANE=", "TMUX_TMPDIR="} {
		for _, line := range env {
			if strings.HasPrefix(line, key) {
				t.Errorf("child inherited %q", line)
			}
		}
	}
	if !contains(env, "QMTEST_STUB_DIR="+dir) {
		t.Fatal("child environment lost unrelated variables; the filter is too broad")
	}
}

func TestRunnerRefusesCallsThatSelectAnotherServer(t *testing.T) {
	dir := fakeTmux(t)
	r := &Runner{socket: "/tmp/qmt-short/tmux.sock"}

	tests := map[string][]string{
		"-S in the command position": {"-S", "/tmp/other.sock", "list-sessions"},
		"-L in the command position": {"-L", "default", "list-sessions"},
	}
	for name, args := range tests {
		t.Run(name, func(t *testing.T) {
			if _, err := r.Run(t.Context(), args...); err == nil {
				t.Fatalf("Run(%q) succeeded, want an error", args)
			}
		})
	}
	if stubRan(dir) {
		t.Fatal("tmux was started for a call that selects another server")
	}
}

func TestCheckSocketPath(t *testing.T) {
	t.Parallel()
	const uid = 501

	tests := map[string]struct {
		socket  string
		wantErr bool
	}{
		"private temp path":             {socket: "/var/folders/x/T/qmt123/tmux.sock"},
		"longest allowed path":          {socket: pathOfLength(maxSocketPathBytes)},
		"one byte too long":             {socket: pathOfLength(maxSocketPathBytes + 1), wantErr: true},
		"default socket":                {socket: "/tmp/tmux-501/default", wantErr: true},
		"default dir under private tmp": {socket: "/private/tmp/tmux-501/default", wantErr: true},
		"other uid shares no prefix":    {socket: "/tmp/tmux-5010/default"},
	}
	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			err := checkSocketPath(tc.socket, uid)
			if (err != nil) != tc.wantErr {
				t.Fatalf("checkSocketPath(%q) error = %v, wantErr %v", tc.socket, err, tc.wantErr)
			}
		})
	}
}

// pathOfLength returns an absolute path of exactly n bytes.
func pathOfLength(n int) string {
	const base = "/var/folders/x/T/"
	return base + strings.Repeat("s", n-len(base))
}

func TestChildEnvStripsOnlyTmuxRoutingVariables(t *testing.T) {
	t.Parallel()
	environ := []string{"TMUX=a", "TMUX_PANE=b", "TMUX_TMPDIR=c", "TMUX_EXTRA=keep", "PATH=/bin"}

	got := childEnv(environ)

	want := []string{"TMUX_EXTRA=keep", "PATH=/bin"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("childEnv = %q, want %q", got, want)
	}
}

func TestRequireIntegrationSkipsUnlessFlagSetAndLogsVersion(t *testing.T) {
	dir := fakeTmux(t)

	var reachedWithoutFlag bool
	t.Run("flag unset", func(t *testing.T) {
		t.Setenv(integrationEnv, "")
		RequireIntegration(t)
		reachedWithoutFlag = true
	})
	if reachedWithoutFlag {
		t.Fatal("RequireIntegration did not skip without the integration flag")
	}
	if stubRan(dir) {
		t.Fatal("tmux was started while the integration flag was unset")
	}

	var reachedWithFlag bool
	t.Run("flag set", func(t *testing.T) {
		t.Setenv(integrationEnv, "1")
		RequireIntegration(t)
		reachedWithFlag = true
	})
	if !reachedWithFlag {
		t.Fatal("RequireIntegration skipped with the integration flag set")
	}
	if got := readLines(t, filepath.Join(dir, "argv")); !reflect.DeepEqual(got, []string{"-V"}) {
		t.Fatalf("tmux argv with the flag set = %q, want only -V", got)
	}
}

func contains(lines []string, want string) bool {
	for _, line := range lines {
		if line == want {
			return true
		}
	}
	return false
}
