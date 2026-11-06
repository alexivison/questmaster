package tmuxconfig_test

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexivison/questmaster/internal/tmux/tmuxtest"
	"github.com/alexivison/questmaster/internal/tmuxconfig"
)

func TestIntegrationTemplateLoadsCleanly(t *testing.T) {
	tmuxtest.RequireIntegration(t)
	t.Setenv("QUESTMASTER_TMUX_LABEL", "questmaster")
	root := t.TempDir()
	if err := tmuxconfig.Prepare(root); err != nil {
		t.Fatal(err)
	}
	paths := tmuxconfig.Paths(root)
	r := tmuxtest.NewRunnerWithConfig(t, paths.Config, paths.Enforced)
	mustTmux(t, r, "new-session", "-d", "-s", "test", "sleep 60")
	if got := mustTmux(t, r, "source-file", "-n", paths.Config); got != "" {
		t.Fatalf("parse output = %q", got)
	}
	for opt, want := range map[string]string{
		"prefix": "C-s", "status-position": "top", "extended-keys-format": "csi-u", "history-limit": "50000", "mouse": "on", "mode-keys": "vi", "exit-empty": "off", "destroy-unattached": "off", "detach-on-destroy": "on",
	} {
		if got := mustTmux(t, r, "show-options", "-gv", opt); got != want {
			t.Errorf("%s = %q, want %q", opt, got, want)
		}
	}
	if got := mustTmux(t, r, "show-options", "-gv", "@questmaster_root"); got != tmuxconfig.RootMarker(root, "questmaster") {
		t.Errorf("root hash = %q", got)
	}
	if got := mustTmux(t, r, "list-keys", "-T", "root", "C-j"); !strings.Contains(got, "ps -o state=") || !strings.Contains(got, "select-pane -D") {
		t.Errorf("C-j binding = %q", got)
	}
	if got := mustTmux(t, r, "show-environment", "-g", "is_vim"); got != "" {
		t.Errorf("is_vim leaked into environment: %q", got)
	}
}

func TestIntegrationRenderQuotesPaths(t *testing.T) {
	tmuxtest.RequireIntegration(t)
	root := filepath.Join(t.TempDir(), "it's a space")
	if err := tmuxconfig.Prepare(root); err != nil {
		t.Fatal(err)
	}
	errors, err := tmuxconfig.Check(t.Context(), tmuxconfig.Paths(root).Config)
	if err != nil || len(errors) != 0 {
		t.Fatalf("Check: errors %q, err %v", errors, err)
	}
}

func TestIntegrationEnforcedWinsOverEdits(t *testing.T) {
	tmuxtest.RequireIntegration(t)
	root := t.TempDir()
	if err := tmuxconfig.Prepare(root); err != nil {
		t.Fatal(err)
	}
	paths := tmuxconfig.Paths(root)
	if err := os.WriteFile(paths.Config, []byte("set -s exit-empty on\nset -g destroy-unattached on\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	r := tmuxtest.NewRunnerWithConfig(t, paths.Config, paths.Enforced)
	mustTmux(t, r, "new-session", "-d", "-s", "test", "sleep 60")
	for opt := range map[string]bool{"exit-empty": true, "destroy-unattached": true} {
		if got := mustTmux(t, r, "show-options", "-gv", opt); got != "off" {
			t.Errorf("%s = %q", opt, got)
		}
	}
}

func TestIntegrationParseErrorKeepsEnforced(t *testing.T) {
	tmuxtest.RequireIntegration(t)
	root := t.TempDir()
	if err := tmuxconfig.Prepare(root); err != nil {
		t.Fatal(err)
	}
	paths := tmuxconfig.Paths(root)
	// tmux 3.8 applies valid lines before the error, so enforced.conf must
	// override the user's earlier exit-empty setting.
	if err := os.WriteFile(paths.Config, []byte("set -s exit-empty on\ninvalid-tmux-command\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	r := tmuxtest.NewRunnerWithConfig(t, paths.Config, paths.Enforced)
	mustTmux(t, r, "new-session", "-d", "-s", "test", "sleep 60")
	if got := mustTmux(t, r, "show-options", "-gv", "exit-empty"); got != "off" {
		t.Errorf("exit-empty = %q", got)
	}
	errors, err := tmuxconfig.Check(t.Context(), paths.Config)
	if err != nil {
		t.Fatal(err)
	}
	if len(errors) == 0 || !strings.Contains(strings.Join(errors, "\n"), fmt.Sprintf("%s:2", paths.Config)) {
		t.Fatalf("parse errors = %q", errors)
	}
}

func TestIntegrationConfigReadOnlyAtStart(t *testing.T) {
	tmuxtest.RequireIntegration(t)
	root := t.TempDir()
	if err := tmuxconfig.Prepare(root); err != nil {
		t.Fatal(err)
	}
	paths := tmuxconfig.Paths(root)
	r := tmuxtest.NewRunnerWithConfig(t, paths.Config, paths.Enforced)
	mustTmux(t, r, "new-session", "-d", "-s", "test", "sleep 60")
	if err := os.WriteFile(paths.Config, []byte("set -g mouse off\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := mustTmux(t, r, "show-options", "-gv", "mouse"); got != "on" {
		t.Fatalf("mouse after edit = %q", got)
	}
}

func mustTmux(t *testing.T, r *tmuxtest.Runner, args ...string) string {
	t.Helper()
	out, err := r.Run(t.Context(), args...)
	if err != nil {
		t.Fatalf("tmux %q: %v", args, err)
	}
	return out
}
