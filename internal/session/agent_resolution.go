package session

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/alexivison/questmaster/internal/agent"
)

const loginShellPathMarker = "__QUESTMASTER_LOGIN_PATH__="

func defaultAgentPath() string {
	home := os.Getenv("HOME")
	return mergePathLists(filepath.Join(home, ".local/bin"), "/opt/homebrew/bin", os.Getenv("PATH"))
}

func resolveAgentBinary(provider agent.Agent, agentPath string) (string, string, bool) {
	return resolveAgentBinaryForLaunch(provider, "", agentPath)
}

func resolveAgentBinaryForLaunch(provider agent.Agent, preferred string, agentPath string) (string, string, bool) {
	if v := os.Getenv(provider.BinaryEnvVar()); v != "" {
		return v, agentPathWithBinaryDir(agentPath, v), true
	}
	if preferred = strings.TrimSpace(preferred); preferred != "" {
		return preferred, agentPathWithBinaryDir(agentPath, preferred), true
	}

	if p, ok := resolveFromPath(provider.Binary(), agentPath); ok {
		return p, agentPathWithBinaryDir(agentPath, p), true
	}

	if loginPath := interactiveLoginShellPath(); loginPath != "" {
		resolvedPath := mergePathLists(agentPath, loginPath)
		if p, ok := resolveFromPath(provider.Binary(), resolvedPath); ok {
			return p, agentPathWithBinaryDir(resolvedPath, p), true
		}
	}

	fallback := expandUserPath(provider.FallbackPath())
	if fallback == "" {
		return "", agentPath, false
	}
	if fileExists(fallback) {
		return fallback, agentPathWithBinaryDir(agentPath, fallback), true
	}
	return fallback, agentPath, false
}

func resolveFromPath(name, path string) (string, bool) {
	name = strings.TrimSpace(name)
	if name == "" {
		return "", false
	}
	if p, err := exec.LookPath(name); err == nil {
		return p, true
	}
	if p, ok := lookPathInPath(name, path); ok {
		return p, true
	}
	return "", false
}

func lookPathInPath(name, path string) (string, bool) {
	if name == "" {
		return "", false
	}
	if strings.ContainsRune(name, os.PathSeparator) {
		name = expandUserPath(name)
		if isExecutableFile(name) {
			return name, true
		}
		return "", false
	}
	for _, dir := range filepath.SplitList(path) {
		if dir == "" {
			continue
		}
		candidate := filepath.Join(dir, name)
		if isExecutableFile(candidate) {
			return candidate, true
		}
	}
	return "", false
}

func interactiveLoginShellPath() string {
	shell := resolveLoginShell()
	if shell == "" {
		return ""
	}

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	// Shell managers such as fnm often install shims from interactive startup
	// files, so a plain login shell is not enough for agent CLI discovery.
	cmd := exec.CommandContext(ctx, shell, "-l", "-i", "-c", "printf '"+loginShellPathMarker+"%s\\n' \"$PATH\"")
	cmd.Env = os.Environ()
	var stdout bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &bytes.Buffer{}
	if err := cmd.Run(); err != nil {
		return ""
	}
	for _, line := range strings.Split(stdout.String(), "\n") {
		if strings.HasPrefix(line, loginShellPathMarker) {
			return strings.TrimPrefix(line, loginShellPathMarker)
		}
	}
	return ""
}

func resolveLoginShell() string {
	shell := strings.TrimSpace(os.Getenv("SHELL"))
	if shell != "" {
		if p, ok := lookPathInPath(shell, os.Getenv("PATH")); ok {
			return p
		}
	}
	for _, candidate := range []string{"/bin/zsh", "/bin/bash", "/bin/sh"} {
		if isExecutableFile(candidate) {
			return candidate
		}
	}
	return ""
}

func agentPathWithBinaryDir(agentPath, binary string) string {
	binary = expandUserPath(binary)
	if !filepath.IsAbs(binary) {
		return agentPath
	}
	return mergePathLists(filepath.Dir(binary), agentPath)
}

func mergePathLists(paths ...string) string {
	var merged []string
	seen := map[string]struct{}{}
	for _, path := range paths {
		for _, dir := range filepath.SplitList(path) {
			if dir == "" {
				continue
			}
			if _, ok := seen[dir]; ok {
				continue
			}
			seen[dir] = struct{}{}
			merged = append(merged, dir)
		}
	}
	return strings.Join(merged, string(os.PathListSeparator))
}

func isExecutableFile(path string) bool {
	info, err := os.Stat(path)
	return err == nil && !info.IsDir() && info.Mode()&0o111 != 0
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func agentBinaryNotFoundError(provider agent.Agent) error {
	return fmt.Errorf("questmaster: %s CLI not found.\n  Tried: %s, PATH lookup for %q, interactive login-shell PATH lookup, and fallback %q.\n  Set %s=/path/to/%s to override, or install the %s CLI.",
		provider.Name(),
		provider.BinaryEnvVar(),
		provider.Binary(),
		provider.FallbackPath(),
		provider.BinaryEnvVar(),
		provider.Binary(),
		provider.Name(),
	)
}

func expandUserPath(path string) string {
	if path == "" || path[0] != '~' {
		return path
	}
	home := os.Getenv("HOME")
	switch {
	case path == "~":
		return home
	case strings.HasPrefix(path, "~/"):
		return filepath.Join(home, path[2:])
	default:
		return path
	}
}
