//go:build linux || darwin

package daemon

import (
	"context"
	"os"
	"os/exec"
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

func TestDaemonShimsTargetIdentityBinaryAndRewrite(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	for _, id := range []string{"canonical", "dev-abc"} {
		t.Run(id, func(t *testing.T) {
			first := filepath.Join(root, "binary ' one")
			second := filepath.Join(root, "binary two")
			for path, label := range map[string]string{first: "first", second: "second"} {
				if err := os.WriteFile(path, []byte("#!/bin/sh\nprintf '"+label+":%s' \"$1\"\n"), 0o700); err != nil {
					t.Fatal(err)
				}
			}
			for _, tc := range []struct{ target, want string }{{first, "first:hello"}, {second, "second:hello"}} {
				if err := writeShims(root, id, tc.target); err != nil {
					t.Fatal(err)
				}
				for _, name := range []string{"qm", "questmaster"} {
					shim := filepath.Join(root, "daemon", "bin", id, name)
					output, err := exec.Command(shim, "hello").Output()
					if err != nil || string(output) != tc.want {
						t.Fatalf("%s output=%q err=%v, want %q", shim, output, err, tc.want)
					}
				}
			}
		})
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
