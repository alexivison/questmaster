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
		"prefix": "C-s", "status-position": "top", "history-limit": "50000", "mouse": "on", "mode-keys": "vi", "exit-empty": "off", "destroy-unattached": "off", "detach-on-destroy": "on",
	} {
		if got := mustTmux(t, r, "show-options", "-gv", opt); got != want {
			t.Errorf("%s = %q, want %q", opt, got, want)
		}
	}
	if got := mustTmux(t, r, "show-options", "-gqv", "extended-keys-format"); got != "" && got != "csi-u" {
		t.Errorf("extended-keys-format = %q, want csi-u where supported", got)
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
	paths := tmuxconfig.Paths(root)
	errors, err := tmuxconfig.Check(t.Context(), paths.Config, paths.Enforced)
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
	if err := os.WriteFile(paths.Config, []byte("set -s exit-empty on\nset -s exit-unattached on\nset -g destroy-unattached on\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	r := tmuxtest.NewRunnerWithConfig(t, paths.Config, paths.Enforced)
	mustTmux(t, r, "new-session", "-d", "-s", "test", "sleep 60")
	for opt := range map[string]bool{"exit-empty": true, "exit-unattached": true, "destroy-unattached": true} {
		if got := mustTmux(t, r, "show-options", "-gv", opt); got != "off" {
			t.Errorf("%s = %q", opt, got)
		}
	}
}

func TestIntegrationParseErrorKeepsEnforced(t *testing.T) {
	tmuxtest.RequireIntegration(t)
	// On tmux 3.8, an unterminated quote can leave earlier lines applied;
	// an unknown command or unclosed brace can discard them. Enforced settings
	// must load after either kind of error.
	for _, tc := range []struct{ name, config, diagnostic string }{
		{"unknown command", "set -s exit-empty on\ninvalid-tmux-command\n", "unknown command"},
		{"unterminated quote", "set -s exit-empty on\nset -g status-left \"unterminated\\", "syntax error"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			root := t.TempDir()
			if err := tmuxconfig.Prepare(root); err != nil {
				t.Fatal(err)
			}
			paths := tmuxconfig.Paths(root)
			if err := os.WriteFile(paths.Config, []byte(tc.config), 0o600); err != nil {
				t.Fatal(err)
			}
			r := tmuxtest.NewRunnerWithConfig(t, paths.Config, paths.Enforced)
			mustTmux(t, r, "new-session", "-d", "-s", "test", "sleep 60")
			if got := mustTmux(t, r, "show-options", "-gv", "@questmaster_enforced"); got != "1" {
				t.Errorf("enforced marker = %q", got)
			}
			if got := mustTmux(t, r, "show-options", "-gv", "exit-empty"); got != "off" {
				t.Errorf("exit-empty = %q", got)
			}
			errors, err := tmuxconfig.Check(t.Context(), paths.Config)
			if err != nil {
				t.Fatal(err)
			}
			diagnostic := strings.Join(errors, "\n")
			if !strings.Contains(diagnostic, fmt.Sprintf("%s:2", paths.Config)) || !strings.Contains(strings.ToLower(diagnostic), tc.diagnostic) {
				t.Fatalf("parse errors = %q", errors)
			}
		})
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
