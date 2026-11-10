package cmd

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/spf13/cobra"
)

func TestSkillsCheckDryRunAndUninstallDryRun(t *testing.T) {
	home := t.TempDir()
	config := filepath.Join(home, "custom-claude")
	stateRoot := filepath.Join(home, "state")
	t.Setenv("HOME", home)
	t.Setenv("CLAUDE_CONFIG_DIR", config)
	t.Setenv("QUESTMASTER_STATE_ROOT", stateRoot)
	t.Setenv("QUESTMASTER_TMUX_LABEL", "")

	root, out, errOut := newSkillsTestRoot()
	root.SetArgs([]string{"skills", "install", "--check"})
	if err := root.Execute(); err == nil {
		t.Fatal("check succeeded before install")
	}
	if !strings.Contains(out.String(), "NotInstalled") {
		t.Fatalf("check output = %q", out.String())
	}
	if _, err := os.Stat(filepath.Join(home, ".agents", "skills")); !os.IsNotExist(err) {
		t.Fatalf("check created skill destination: %v", err)
	}
	if errOut.Len() != 0 {
		t.Fatalf("check wrote to stderr: %q", errOut.String())
	}

	root, out, _ = newSkillsTestRoot()
	root.SetArgs([]string{"skills", "install", "--dry-run"})
	if err := root.Execute(); err != nil {
		t.Fatalf("install dry-run: %v", err)
	}
	if !strings.Contains(out.String(), "would install") || !strings.Contains(out.String(), "custom-claude/skills") {
		t.Fatalf("dry-run output = %q", out.String())
	}
	if _, err := os.Stat(filepath.Join(home, ".agents", "skills")); !os.IsNotExist(err) {
		t.Fatalf("dry-run created skill destination: %v", err)
	}

	root, _, errOut = newSkillsTestRoot()
	root.SetArgs([]string{"skills", "install"})
	if err := root.Execute(); err != nil {
		t.Fatalf("install: %v", err)
	}
	if !strings.Contains(errOut.String(), "installed") {
		t.Fatalf("install action output = %q", errOut.String())
	}
	if _, err := os.Stat(filepath.Join(config, "skills", "questmaster-write-quest", "SKILL.md")); err != nil {
		t.Fatalf("Claude config override was not used: %v", err)
	}

	root, out, _ = newSkillsTestRoot()
	root.SetArgs([]string{"skills", "install", "--check"})
	if err := root.Execute(); err != nil {
		t.Fatalf("check after install: %v", err)
	}
	if !strings.Contains(out.String(), "Current") {
		t.Fatalf("current check output = %q", out.String())
	}

	root, out, _ = newSkillsTestRoot()
	root.SetArgs([]string{"skills", "uninstall", "--dry-run"})
	if err := root.Execute(); err != nil {
		t.Fatalf("uninstall dry-run: %v", err)
	}
	if !strings.Contains(out.String(), "would remove") {
		t.Fatalf("uninstall dry-run output = %q", out.String())
	}
	if _, err := os.Stat(filepath.Join(config, "skills", "questmaster-write-quest", "SKILL.md")); err != nil {
		t.Fatalf("uninstall dry-run removed skill: %v", err)
	}
}

func TestSkillsCommandHasNoAgentSelector(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("CLAUDE_CONFIG_DIR", filepath.Join(t.TempDir(), "claude"))
	t.Setenv("QUESTMASTER_TMUX_LABEL", "")
	root, _, _ := newSkillsTestRoot()
	root.SetArgs([]string{"skills", "status", "claude"})
	if err := root.Execute(); err == nil {
		t.Fatal("skills status accepted an agent selector")
	}
}

func TestSkillsTreeBypassesRouterConstructionFailureOnly(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("CLAUDE_CONFIG_DIR", filepath.Join(home, "claude"))
	t.Setenv("QUESTMASTER_STATE_ROOT", filepath.Join(home, "state"))
	t.Setenv("QUESTMASTER_TMUX_LABEL", "invalid label")

	root, out, _ := newSkillsTestRoot()
	root.SetArgs([]string{"skills", "status"})
	if err := root.Execute(); err != nil {
		t.Fatalf("skills status should bypass router construction error: %v", err)
	}
	if !strings.Contains(out.String(), "NotInstalled") {
		t.Fatalf("skills status output = %q", out.String())
	}

	for _, args := range [][]string{{"list"}, {"sessions"}} {
		root, _, _ := newSkillsTestRoot()
		root.SetArgs(args)
		if err := root.Execute(); err == nil || !strings.Contains(err.Error(), "QUESTMASTER_TMUX_LABEL") {
			t.Fatalf("%v error = %v, want router construction error", args, err)
		}
	}
}

func newSkillsTestRoot() (*cobra.Command, *bytes.Buffer, *bytes.Buffer) {
	root := NewRootCmd()
	var out, errOut bytes.Buffer
	root.SetOut(&out)
	root.SetErr(&errOut)
	return root, &out, &errOut
}
