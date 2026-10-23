//go:build linux || darwin

package daemon

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

const systemPath = "/usr/bin:/bin:/usr/sbin:/sbin"

type LoginEnvironmentRunner func(context.Context, string, []string) ([]byte, error)

func runLoginEnvironment(ctx context.Context, shell string, base []string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, shell, "-l", "-c", "env -0")
	cmd.Env = base
	cmd.Stderr = io.Discard
	cmd.WaitDelay = 100 * time.Millisecond
	output := cappedOutput{limit: 1 << 20}
	cmd.Stdout = &output // exec copies the pipe concurrently while waiting.
	err := cmd.Run()
	if err != nil {
		return nil, err
	}
	return output.Bytes(), nil
}

type cappedOutput struct {
	bytes.Buffer
	limit int
}

func (w *cappedOutput) Write(data []byte) (int, error) {
	if len(data) > w.limit-w.Len() {
		return 0, fmt.Errorf("login environment exceeds 1 MiB")
	}
	return w.Buffer.Write(data)
}

func (c Config) daemonEnvironment(id string) map[string]string {
	base := map[string]string{"PATH": systemPath}
	for _, key := range []string{"HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "SSH_AUTH_SOCK"} {
		if value := os.Getenv(key); value != "" {
			base[key] = value
		}
	}
	base["HOME"] = c.Home
	if base["SHELL"] == "" {
		base["SHELL"] = "/bin/zsh"
	}
	if !filepath.IsAbs(base["SHELL"]) {
		base["SHELL"] = "/bin/zsh"
	}
	if info, err := os.Stat(base["SHELL"]); err != nil || info.Mode().Perm()&0o111 == 0 {
		base["SHELL"] = "/bin/sh"
	}
	if base["LANG"] == "" {
		base["LANG"] = "en_US.UTF-8"
	}
	env := make(map[string]string, len(base)+8)
	for key, value := range base {
		env[key] = value
	}
	runner := c.LoginEnvironmentRunner
	if runner == nil {
		runner = runLoginEnvironment
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	baseList := make([]string, 0, len(base))
	for key, value := range base {
		baseList = append(baseList, key+"="+value)
	}
	if raw, err := runner(ctx, base["SHELL"], baseList); err == nil {
		for _, pair := range bytes.Split(raw, []byte{0}) {
			key, value, ok := bytes.Cut(pair, []byte{'='})
			if !ok {
				continue
			}
			if index := bytes.LastIndexByte(key, '\n'); index >= 0 {
				key = key[index+1:] // Some login shells print a banner before env.
			}
			if !importLoginKey(string(key)) {
				continue
			}
			env[string(key)] = string(value)
		}
	}
	for _, key := range []string{"HOME", "SHELL", "LANG"} {
		if env[key] == "" {
			env[key] = base[key]
		}
	}
	if env["XDG_CONFIG_HOME"] == "" {
		env["XDG_CONFIG_HOME"] = filepath.Join(env["HOME"], ".config")
	}
	for _, key := range []string{"QUESTMASTER_HOME", "QUESTMASTER_QM", "QUESTMASTER_SESSION", "TERM", "COLORTERM"} {
		delete(env, key)
	}
	prefix := filepath.Join(c.Root, "daemon", "bin", id)
	env["QUESTMASTER_STATE_ROOT"] = c.Root
	env["QUESTMASTER_APP"] = "1"
	env["QUESTMASTER_BIN"] = filepath.Join(prefix, "qm")
	if id == "canonical" {
		env["QUESTMASTER_BIN"] = c.Executable
	}
	env["QUESTMASTER_PATH_PREFIX"] = prefix
	env["PATH"] = prependPath(prefix, normalizedPath(env["PATH"], env["HOME"]))
	return env
}

func importLoginKey(key string) bool {
	if key == "" || strings.Contains(key, "=") || key == "PWD" || key == "OLDPWD" || key == "SHLVL" || key == "_" || strings.HasPrefix(key, "TMUX") {
		return false
	}
	return true
}

func normalizedPath(path, home string) string {
	configured := strings.Split(path, ":")
	defaults := []string{
		filepath.Join(home, ".local", "bin"), filepath.Join(home, "bin"), filepath.Join(home, ".cargo", "bin"),
		"/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin",
		"/usr/bin", "/bin", "/usr/sbin", "/sbin",
	}
	hasDeveloperPath := false
	for _, directory := range configured {
		if directory == "/opt/homebrew/bin" || directory == "/usr/local/bin" || directory == defaults[0] {
			hasDeveloperPath = true
			break
		}
	}
	if hasDeveloperPath {
		return prependPathList(configured, defaults)
	}
	return prependPathList(defaults, configured)
}

func prependPath(prefix, path string) string {
	return prependPathList([]string{prefix}, strings.Split(path, ":"))
}

func prependPathList(first, second []string) string {
	seen := map[string]bool{}
	parts := make([]string, 0, len(first)+len(second))
	for _, part := range append(append([]string{}, first...), second...) {
		if part != "" && !seen[part] {
			seen[part] = true
			parts = append(parts, part)
		}
	}
	return strings.Join(parts, ":")
}

func installEnvironment(env map[string]string) error {
	os.Clearenv()
	for key, value := range env {
		if err := os.Setenv(key, value); err != nil {
			return err
		}
	}
	return nil
}
