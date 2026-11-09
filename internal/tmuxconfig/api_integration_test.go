package tmuxconfig_test

import (
	"os"
	"strings"
	"testing"

	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmux/tmuxtest"
	"github.com/alexivison/questmaster/internal/tmuxconfig"
)

func configServer(t *testing.T) (*tmuxtest.Runner, *tmux.Client, string) {
	t.Helper()
	root := t.TempDir()
	t.Setenv("HOME", t.TempDir())
	t.Setenv("QUESTMASTER_STATE_ROOT", root)
	t.Setenv("QUESTMASTER_TMUX_LABEL", "testconfig")
	if err := prepareConfig(t, root); err != nil {
		t.Fatal(err)
	}
	paths := tmuxconfig.Paths(root)
	r := tmuxtest.NewRunnerWithConfig(t, paths.Config, paths.Enforced)
	return r, tmux.NewClient(r), root
}

func TestIntegrationRestartRefusedWithSessions(t *testing.T) {
	tmuxtest.RequireIntegration(t)
	r, client, root := configServer(t)
	mustTmux(t, r, "new-session", "-d", "-s", "test", "sleep 60")
	result, err := tmuxconfig.RestartIfEmpty(t.Context(), client, root)
	if err != nil || result.Restarted || !result.Refused || result.Sessions != 1 {
		t.Fatalf("restart with session: %+v, %v", result, err)
	}
	if got := mustTmux(t, r, "list-sessions", "-F", "#{session_name}"); got != "test" {
		t.Fatalf("live session lost: %q", got)
	}
}

func TestIntegrationRestartWhenEmpty(t *testing.T) {
	tmuxtest.RequireIntegration(t)
	r, client, root := configServer(t)
	mustTmux(t, r, "new-session", "-d", "-s", "test", "sleep 60")
	mustTmux(t, r, "kill-session", "-t", tmux.SessionTarget("test"))
	result, err := tmuxconfig.RestartIfEmpty(t.Context(), client, root)
	if err != nil || !result.Restarted || result.Refused || result.Sessions != 0 {
		t.Fatalf("restart empty: %+v, %v", result, err)
	}
	status, err := tmuxconfig.Status(t.Context(), client, root)
	if err != nil || status.Running {
		t.Fatalf("server still running: %+v, %v", status, err)
	}
}

func TestIntegrationReloadReportsErrorsAndRestoresEnforced(t *testing.T) {
	tmuxtest.RequireIntegration(t)
	r, client, root := configServer(t)
	mustTmux(t, r, "new-session", "-d", "-s", "test", "sleep 60")
	path := tmuxconfig.Paths(root).Config
	if err := os.WriteFile(path, []byte("set -g destroy-unattached on\ninvalid-tmux-command\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	result, err := tmuxconfig.Reload(t.Context(), client, root)
	if err != nil || !result.Running || len(result.Errors) == 0 {
		t.Fatalf("reload errors: %+v, %v", result, err)
	}
	if got := mustTmux(t, r, "show-options", "-gv", "destroy-unattached"); got != "off" {
		t.Fatalf("enforced option after failed user source = %q", got)
	}
}

func TestIntegrationReloadAppliesNewValue(t *testing.T) {
	tmuxtest.RequireIntegration(t)
	r, client, root := configServer(t)
	mustTmux(t, r, "new-session", "-d", "-s", "test", "sleep 60")
	path := tmuxconfig.Paths(root).Config
	if err := os.WriteFile(path, []byte("set -g mouse off\nbind-key F12 display-message kept\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	result, err := tmuxconfig.Reload(t.Context(), client, root)
	if err != nil || !result.Running || len(result.Errors) != 0 {
		t.Fatalf("reload: %+v, %v", result, err)
	}
	if got := mustTmux(t, r, "show-options", "-gv", "mouse"); got != "off" {
		t.Fatalf("mouse = %q", got)
	}
	if err := os.WriteFile(path, []byte("set -g mouse on\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	result, err = tmuxconfig.Reload(t.Context(), client, root)
	if err != nil || len(result.Errors) != 0 {
		t.Fatalf("second reload: %+v, %v", result, err)
	}
	// tmux source-file is additive: removing a bind-key line does not unbind it.
	if got := mustTmux(t, r, "list-keys", "-T", "prefix", "F12"); !strings.Contains(got, "kept") {
		t.Fatalf("removed binding unexpectedly disappeared: %q", got)
	}
}
