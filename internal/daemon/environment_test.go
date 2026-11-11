//go:build linux || darwin

package daemon

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDaemonEnvironmentUsesAllowlistedBaseAndCapturedLogin(t *testing.T) {
	root := t.TempDir()
	home := t.TempDir()
	for key, value := range map[string]string{
		"HOME": home, "SHELL": "/bin/sh", "SSH_AUTH_SOCK": "/tmp/agent.sock",
		"CLAUDECODE": "pane", "TMUX": "pane", "TERM": "xterm", "QUESTMASTER_SESSION": "qm-pane",
		"PATH": "/pane/odd", "QUESTMASTER_QM": "/pane/qm",
	} {
		t.Setenv(key, value)
	}
	c := Config{Root: root, Home: home, LoginEnvironmentRunner: func(_ context.Context, shell string, base []string) ([]byte, error) {
		if shell != "/bin/sh" {
			t.Fatalf("shell=%s", shell)
		}
		allowed := map[string]bool{"HOME": true, "USER": true, "LOGNAME": true, "SHELL": true, "TMPDIR": true, "LANG": true, "SSH_AUTH_SOCK": true, "PATH": true}
		for _, pair := range base {
			key, value, _ := strings.Cut(pair, "=")
			if !allowed[key] || key == "PATH" && value != systemPath {
				t.Fatalf("polluted capture base: %s", pair)
			}
		}
		return []byte("login banner\nPATH=/captured/bin:/usr/local/bin\x00CODEX_HOME=/captured/codex\x00PWD=/bad\x00TMUX_PANE=/bad\x00"), nil
	}}
	env := c.daemonEnvironment("dev-abc")
	for _, key := range []string{"CLAUDECODE", "TMUX", "TMUX_PANE", "TERM", "QUESTMASTER_SESSION", "QUESTMASTER_QM", "PWD"} {
		if _, ok := env[key]; ok {
			t.Fatalf("%s leaked into daemon environment", key)
		}
	}
	prefix := filepath.Join(root, "daemon", "bin", "dev-abc")
	if env["SSH_AUTH_SOCK"] != "/tmp/agent.sock" || env["CODEX_HOME"] != "/captured/codex" ||
		env["QUESTMASTER_STATE_ROOT"] != root || env["QUESTMASTER_APP"] != "1" ||
		env["QUESTMASTER_BIN"] != filepath.Join(prefix, "qm") || env["QUESTMASTER_PATH_PREFIX"] != prefix {
		t.Fatalf("missing daemon environment: %+v", env)
	}
	if !strings.HasPrefix(env["PATH"], prefix+":/captured/bin:/usr/local/bin:") || !strings.Contains(env["PATH"], "/usr/bin") || strings.Contains(env["PATH"], "/pane/odd") {
		t.Fatalf("normalized PATH=%q", env["PATH"])
	}
	if env["XDG_CONFIG_HOME"] != filepath.Join(home, ".config") {
		t.Fatalf("XDG_CONFIG_HOME=%q", env["XDG_CONFIG_HOME"])
	}
}

func TestDaemonEnvironmentCarriesStartingTmuxLabel(t *testing.T) {
	t.Setenv("QUESTMASTER_TMUX_LABEL", "dev_test")
	c := Config{Root: t.TempDir(), Home: t.TempDir(), LoginEnvironmentRunner: func(_ context.Context, _ string, base []string) ([]byte, error) {
		return []byte("QUESTMASTER_TMUX_LABEL=login_value\x00"), nil
	}}
	if got := c.daemonEnvironment("dev-example")["QUESTMASTER_TMUX_LABEL"]; got != "dev_test" {
		t.Fatalf("daemon label = %q, want launching value", got)
	}
}

func TestOnlyInstalledIdentitiesGetTheStableExecutableInTheEnvironment(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	for id, want := range map[string]string{
		"canonical":          filepath.Join(root, "bin", "current", "qm"),
		"bin-0123456789abcd": filepath.Join(root, "bin", "current", "qm"),
		"dev-0123456789abcd": filepath.Join(root, "daemon", "bin", "dev-0123456789abcd", "qm"),
	} {
		c := Config{Root: root, Home: t.TempDir(), LoginEnvironmentRunner: func(context.Context, string, []string) ([]byte, error) {
			return nil, context.Canceled
		}}
		if got := c.daemonEnvironment(id)["QUESTMASTER_BIN"]; got != want {
			t.Fatalf("%s QUESTMASTER_BIN = %q, want %q", id, got, want)
		}
	}
}

func TestDaemonEnvironmentFallsBackAfterCaptureTimeout(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("SHELL", "/bin/sh")
	c := Config{Root: t.TempDir(), Home: home, LoginEnvironmentRunner: func(ctx context.Context, _ string, _ []string) ([]byte, error) {
		<-ctx.Done()
		return nil, ctx.Err()
	}}
	env := c.daemonEnvironment("canonical")
	if env["HOME"] != home || env["SHELL"] != "/bin/sh" || env["LANG"] == "" || !strings.Contains(env["PATH"], "/usr/bin") {
		t.Fatalf("fallback environment=%+v", env)
	}
}

func TestDaemonShimNeverReplacesExecutable(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	id := "dev-abc"
	binary := filepath.Join(root, "daemon", "bin", id, "qm")
	if err := os.MkdirAll(filepath.Dir(binary), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(binary, []byte("real binary"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := writeShims(root, id, binary); err == nil {
		t.Fatal("shim writer replaced the executable")
	}
	data, err := os.ReadFile(binary)
	if err != nil || string(data) != "real binary" {
		t.Fatalf("executable was changed: %q %v", data, err)
	}
}

func TestImportLoginKeyFiltersShellState(t *testing.T) {
	t.Parallel()
	for _, key := range []string{"PWD", "OLDPWD", "SHLVL", "_", "TMUX", "TMUX_PANE", "TMUX_TMPDIR", "TMUX_SOCKET", ""} {
		if importLoginKey(key) {
			t.Fatalf("%s imported", key)
		}
	}
	for _, key := range []string{"PATH", "CODEX_HOME", "SSH_AUTH_SOCK"} {
		if !importLoginKey(key) {
			t.Fatalf("%s rejected", key)
		}
	}
}
