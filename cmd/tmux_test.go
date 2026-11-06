package cmd

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexivison/questmaster/internal/tmux/tmuxtest"
	"github.com/alexivison/questmaster/internal/tmuxconfig"
)

func TestTmuxConfigCommandsAreReadOnly(t *testing.T) {
	root := t.TempDir()
	t.Setenv("QUESTMASTER_STATE_ROOT", root)
	t.Setenv("HOME", t.TempDir())
	var out bytes.Buffer
	command := NewRootCmd()
	command.SetOut(&out)
	command.SetArgs([]string{"tmux", "config", "path"})
	if err := command.Execute(); err != nil {
		t.Fatal(err)
	}
	var paths struct {
		Config         string `json:"config"`
		Enforced       string `json:"enforced"`
		Reload         string `json:"reload"`
		StatusScript   string `json:"status_script"`
		EffectiveLabel string `json:"effective_label"`
	}
	if err := json.Unmarshal(out.Bytes(), &paths); err != nil {
		t.Fatal(err)
	}
	if paths.Config != filepath.Join(root, "tmux", "questmaster.conf") || paths.Enforced != filepath.Join(root, "tmux", "enforced.questmaster.conf") || paths.Reload != filepath.Join(root, "tmux", "reload.questmaster.conf") || paths.EffectiveLabel != "questmaster" {
		t.Fatalf("paths = %+v", paths)
	}
	if _, err := os.Stat(filepath.Join(root, "tmux")); !os.IsNotExist(err) {
		t.Fatalf("path command wrote files: %v", err)
	}
	out.Reset()
	command = NewRootCmd()
	command.SetOut(&out)
	command.SetArgs([]string{"tmux", "config", "template"})
	if err := command.Execute(); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "# Questmaster tmux config") || strings.Contains(out.String(), "{{CONFIG}}") {
		t.Fatal("template not rendered")
	}
	if _, err := os.Stat(filepath.Join(root, "tmux")); !os.IsNotExist(err) {
		t.Fatalf("template command wrote files: %v", err)
	}
}

func TestIntegrationTmuxConfigCheckReportsParseErrors(t *testing.T) {
	tmuxtest.RequireIntegration(t)
	root := t.TempDir()
	t.Setenv("QUESTMASTER_STATE_ROOT", root)
	t.Setenv("HOME", t.TempDir())
	file := filepath.Join(t.TempDir(), "broken.conf")
	if err := os.WriteFile(file, []byte("invalid-tmux-command\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	command := NewRootCmd()
	command.SetOut(&out)
	command.SetArgs([]string{"tmux", "config", "check", "--file", file})
	if err := command.Execute(); err != nil {
		t.Fatal(err)
	}
	var result struct {
		OK             bool     `json:"ok"`
		Errors         []string `json:"errors"`
		EffectiveLabel string   `json:"effective_label"`
	}
	if err := json.Unmarshal(out.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if result.OK || len(result.Errors) == 0 || result.EffectiveLabel != "questmaster" {
		t.Fatalf("result = %+v", result)
	}
	if _, err := os.Stat(filepath.Join(root, "tmux")); !os.IsNotExist(err) {
		t.Fatalf("check command wrote files: %v", err)
	}
}

func TestIntegrationTmuxConfigCheckUsesEffectiveLabelFiles(t *testing.T) {
	tmuxtest.RequireIntegration(t)
	root := t.TempDir()
	t.Setenv("QUESTMASTER_STATE_ROOT", root)
	t.Setenv("HOME", t.TempDir())
	t.Setenv("QUESTMASTER_TMUX_LABEL", "dev_check")
	if err := tmuxconfig.Prepare(root); err != nil {
		t.Fatal(err)
	}
	paths := tmuxconfig.Paths(root)
	if err := os.WriteFile(paths.Enforced, []byte("invalid-tmux-command\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	command := NewRootCmd()
	command.SetOut(&out)
	command.SetArgs([]string{"tmux", "config", "check"})
	if err := command.Execute(); err != nil {
		t.Fatal(err)
	}
	var result struct {
		OK             bool     `json:"ok"`
		Errors         []string `json:"errors"`
		EffectiveLabel string   `json:"effective_label"`
	}
	if err := json.Unmarshal(out.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if result.OK || result.EffectiveLabel != "dev_check" || len(result.Errors) == 0 || !strings.Contains(strings.Join(result.Errors, "\n"), paths.Enforced) {
		t.Fatalf("check did not validate label-specific enforcement: %+v", result)
	}
}

func TestIntegrationTmuxConfigCheckCreatesMissingLabelFiles(t *testing.T) {
	tmuxtest.RequireIntegration(t)
	root := t.TempDir()
	t.Setenv("QUESTMASTER_STATE_ROOT", root)
	t.Setenv("HOME", t.TempDir())
	t.Setenv("QUESTMASTER_TMUX_LABEL", "dev_check")
	if err := tmuxconfig.Prepare(root); err != nil {
		t.Fatal(err)
	}
	paths := tmuxconfig.Paths(root)
	for _, path := range []string{paths.Enforced, paths.Reload} {
		if err := os.Remove(path); err != nil {
			t.Fatal(err)
		}
	}
	var out bytes.Buffer
	command := NewRootCmd()
	command.SetOut(&out)
	command.SetArgs([]string{"tmux", "config", "check"})
	if err := command.Execute(); err != nil {
		t.Fatal(err)
	}
	var result struct {
		OK bool `json:"ok"`
	}
	if err := json.Unmarshal(out.Bytes(), &result); err != nil || !result.OK {
		t.Fatalf("check after upgrade: %+v, %v", result, err)
	}
	for _, path := range []string{paths.Enforced, paths.Reload} {
		if _, err := os.Stat(path); err != nil {
			t.Fatalf("missing generated file %s: %v", path, err)
		}
	}
}

func TestTmuxConfigPathReportsOverrideAndRejectsInvalidLabel(t *testing.T) {
	root := t.TempDir()
	t.Setenv("QUESTMASTER_STATE_ROOT", root)
	t.Setenv("HOME", t.TempDir())
	t.Setenv("QUESTMASTER_TMUX_LABEL", "dev_1")
	var out bytes.Buffer
	command := NewRootCmd()
	command.SetOut(&out)
	command.SetArgs([]string{"tmux", "config", "path"})
	if err := command.Execute(); err != nil {
		t.Fatal(err)
	}
	var result struct {
		EffectiveLabel string `json:"effective_label"`
	}
	if err := json.Unmarshal(out.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if result.EffectiveLabel != "dev_1" {
		t.Fatalf("label = %q", result.EffectiveLabel)
	}
	t.Setenv("QUESTMASTER_TMUX_LABEL", "default")
	command = NewRootCmd()
	command.SetOut(&out)
	command.SetArgs([]string{"tmux", "config", "path"})
	if err := command.Execute(); err == nil {
		t.Fatal("accepted invalid label")
	}
}

func TestTmuxConfigCheckHelpWarnsOfLoadTimeCommands(t *testing.T) {
	t.Setenv("QUESTMASTER_STATE_ROOT", t.TempDir())
	var out bytes.Buffer
	command := NewRootCmd()
	command.SetOut(&out)
	command.SetArgs([]string{"tmux", "config", "check", "--help"})
	if err := command.Execute(); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "run-shell") || !strings.Contains(out.String(), "if-shell") {
		t.Fatalf("help omits load-time execution: %s", out.String())
	}
}
