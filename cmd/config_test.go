//go:build linux || darwin

package cmd

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestConfigInitCreatesTemplate(t *testing.T) {
	configRoot := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", configRoot)

	out := runConfigCmd(t, "config", "init")
	if !strings.Contains(out, "config initialized at") {
		t.Fatalf("init output = %q", out)
	}

	configPath := filepath.Join(configRoot, "party-cli", "config.toml")
	body, err := os.ReadFile(configPath)
	if err != nil {
		t.Fatalf("ReadFile(%s): %v", configPath, err)
	}
	if !strings.Contains(string(body), "# party-cli config") {
		t.Fatalf("config template missing comment header: %s", string(body))
	}
	if !strings.Contains(string(body), "[roles.companion]") {
		t.Fatalf("config template missing companion section: %s", string(body))
	}
}

func TestConfigInitIsIdempotent(t *testing.T) {
	configRoot := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", configRoot)

	runConfigCmd(t, "config", "init")
	out := runConfigCmd(t, "config", "init")
	if !strings.Contains(out, "config already exists at") {
		t.Fatalf("second init output = %q", out)
	}
}

func TestConfigPathPrintsUserConfigPath(t *testing.T) {
	configRoot := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", configRoot)

	out := runConfigCmd(t, "config", "path")
	want := filepath.Join(configRoot, "party-cli", "config.toml") + "\n"
	if out != want {
		t.Fatalf("path output = %q, want %q", out, want)
	}
}

func TestConfigSetPrimaryAndShow(t *testing.T) {
	configRoot := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", configRoot)

	runConfigCmd(t, "config", "set-primary", "codex")
	out := runConfigCmd(t, "config", "show")
	if !strings.Contains(out, "[roles.primary]\nagent = \"codex\"") {
		t.Fatalf("show output missing codex primary: %s", out)
	}
}

func TestConfigSetCompanionAndUnset(t *testing.T) {
	configRoot := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", configRoot)

	runConfigCmd(t, "config", "set-companion", "claude")
	out := runConfigCmd(t, "config", "show")
	if !strings.Contains(out, "[roles.companion]\nagent = \"claude\"\nwindow = 0") {
		t.Fatalf("show output missing claude companion: %s", out)
	}

	runConfigCmd(t, "config", "unset-companion")
	out = runConfigCmd(t, "config", "show")
	if strings.Contains(out, "[roles.companion]") {
		t.Fatalf("show output should omit companion section: %s", out)
	}
}

func runConfigCmd(t *testing.T, args ...string) string {
	t.Helper()

	root := NewRootCmd(WithTUILauncher(func() error { return nil }))
	var out bytes.Buffer
	root.SetOut(&out)
	root.SetErr(&bytes.Buffer{})
	root.SetArgs(args)
	if err := root.Execute(); err != nil {
		t.Fatalf("Execute(%v): %v", args, err)
	}
	return out.String()
}
