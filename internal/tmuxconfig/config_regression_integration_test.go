package tmuxconfig_test

import (
	"os"
	"strings"
	"testing"

	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmux/tmuxtest"
	"github.com/alexivison/questmaster/internal/tmuxconfig"
)

// These cases reproduce the config review's private-socket failures.
func TestIntegrationSharedRootReloadKeepsOwnLabel(t *testing.T) {
	tmuxtest.RequireIntegration(t)
	root := t.TempDir()
	t.Setenv("HOME", t.TempDir())
	t.Setenv("QUESTMASTER_STATE_ROOT", root)
	t.Setenv("QUESTMASTER_TMUX_LABEL", "dev_a")
	if err := tmuxconfig.Prepare(root); err != nil {
		t.Fatal(err)
	}
	paths := tmuxconfig.Paths(root)
	userBefore, err := os.ReadFile(paths.Config)
	if err != nil {
		t.Fatal(err)
	}
	a := tmuxtest.NewRunnerWithConfig(t, paths.Config, paths.Enforced)
	mustTmux(t, a, "new-session", "-d", "-s", "test", "sleep 60")
	original := mustTmux(t, a, "show-options", "-gqv", "@questmaster_root")
	t.Setenv("QUESTMASTER_TMUX_LABEL", "dev_b")
	if err := tmuxconfig.Prepare(root); err != nil {
		t.Fatal(err)
	}
	pathsB := tmuxconfig.Paths(root)
	if paths.Enforced == pathsB.Enforced || paths.Reload == pathsB.Reload || paths.Config != pathsB.Config {
		t.Fatalf("paths are not label specific: a=%+v b=%+v", paths, pathsB)
	}
	userAfter, err := os.ReadFile(paths.Config)
	if err != nil || string(userAfter) != string(userBefore) {
		t.Fatalf("shared user config changed: %v", err)
	}
	b := tmuxtest.NewRunnerWithConfig(t, pathsB.Config, pathsB.Enforced)
	mustTmux(t, b, "new-session", "-d", "-s", "test", "sleep 60")
	t.Setenv("QUESTMASTER_TMUX_LABEL", "dev_a")
	result, err := tmuxconfig.Reload(t.Context(), tmux.NewClient(a), root)
	if err != nil || len(result.Errors) != 0 {
		t.Fatalf("reload: %+v %v", result, err)
	}
	marker := mustTmux(t, a, "show-options", "-gqv", "@questmaster_root")
	hook := mustTmux(t, a, "show-hooks", "-g", "session-closed")
	t.Logf("before=%s after=%s hook=%s", original, marker, hook)
	if !tmuxconfig.OwnsRoot(marker, root, "dev_a") || strings.Contains(hook, "--server dev_b") {
		t.Fatal("reload rewrote dev_a ownership or cleanup route with dev_b enforcement")
	}
	if got := mustTmux(t, a, "show-options", "-gqv", "@questmaster_reload_file"); got != paths.Reload {
		t.Fatalf("dev_a reload route = %q, want %q", got, paths.Reload)
	}
	if got := mustTmux(t, b, "show-options", "-gqv", "@questmaster_reload_file"); got != pathsB.Reload {
		t.Fatalf("dev_b reload route = %q, want %q", got, pathsB.Reload)
	}
	if got := mustTmux(t, a, "list-keys", "-T", "prefix", "R"); !strings.Contains(got, "@questmaster_reload_file") {
		t.Fatalf("reload binding does not use the server's label: %q", got)
	}
	// An existing user file can still contain the old binding. The enforced
	// file replaces it on each server, and -F resolves that server's path.
	if err := os.WriteFile(paths.Config, []byte("bind-key R source-file '/tmp/missing-old-enforced.conf'\nset -g mouse off\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	for _, server := range []*tmuxtest.Runner{a, b} {
		mustTmux(t, server, "source-file", "-F", "#{@questmaster_reload_file}")
		if got := mustTmux(t, server, "show-options", "-gqv", "mouse"); got != "off" {
			t.Fatalf("reload binding did not source the shared config: %q", got)
		}
		if got := mustTmux(t, server, "list-keys", "-T", "prefix", "R"); !strings.Contains(got, "@questmaster_reload_file") {
			t.Fatalf("old reload binding survived enforcement: %q", got)
		}
	}
}

func TestIntegrationForeignRootReloadDoesNotAdoptServer(t *testing.T) {
	tmuxtest.RequireIntegration(t)
	t.Setenv("HOME", t.TempDir())
	t.Setenv("QUESTMASTER_TMUX_LABEL", "dev_owned")
	rootA, rootB := t.TempDir(), t.TempDir()
	t.Setenv("QUESTMASTER_STATE_ROOT", rootA)
	if err := tmuxconfig.Prepare(rootA); err != nil {
		t.Fatal(err)
	}
	pathsA := tmuxconfig.Paths(rootA)
	a := tmuxtest.NewRunnerWithConfig(t, pathsA.Config, pathsA.Enforced)
	mustTmux(t, a, "new-session", "-d", "-s", "test", "sleep 60")
	t.Setenv("QUESTMASTER_STATE_ROOT", rootB)
	if err := tmuxconfig.Prepare(rootB); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(tmuxconfig.Paths(rootB).Config, []byte("set -g mouse off\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	result, err := tmuxconfig.Reload(t.Context(), tmux.NewClient(a), rootB)
	marker := mustTmux(t, a, "show-options", "-gqv", "@questmaster_root")
	t.Logf("reload=%+v error=%v marker=%s", result, err, marker)
	if err == nil || !strings.Contains(err.Error(), "unmarked or belongs to another state root") || tmuxconfig.OwnsRoot(marker, rootB, "dev_owned") {
		t.Fatal("reload adopted another root's live server or did not report foreign ownership")
	}
	if got := mustTmux(t, a, "show-options", "-gqv", "mouse"); got != "on" {
		t.Fatalf("foreign config changed mouse: %q", got)
	}
}

func TestIntegrationReloadEnforcedSettingsDoNotKillLiveSessions(t *testing.T) {
	tmuxtest.RequireIntegration(t)
	for _, option := range []string{"destroy-unattached", "exit-unattached", "exit-empty"} {
		t.Run(option, func(t *testing.T) {
			r, client, root := configServer(t)
			mustTmux(t, r, "new-session", "-d", "-s", "test", "sleep 60")
			if err := os.WriteFile(tmuxconfig.Paths(root).Config, []byte("set -g "+option+" on\n"), 0o600); err != nil {
				t.Fatal(err)
			}
			result, err := tmuxconfig.Reload(t.Context(), client, root)
			if err != nil || len(result.Errors) != 0 {
				t.Fatalf("reload: %+v, %v", result, err)
			}
			if sessions := mustTmux(t, r, "list-sessions", "-F", "#{session_name}"); sessions != "test" {
				t.Fatalf("session lost after %s on: %q", option, sessions)
			}
			if got := mustTmux(t, r, "show-options", "-gqv", option); got != "off" {
				t.Fatalf("%s after reload = %q", option, got)
			}
		})
	}
}

func TestIntegrationConfigMutationsRejectUnmarkedServer(t *testing.T) {
	tmuxtest.RequireIntegration(t)
	root := t.TempDir()
	t.Setenv("HOME", t.TempDir())
	t.Setenv("QUESTMASTER_STATE_ROOT", root)
	t.Setenv("QUESTMASTER_TMUX_LABEL", "dev_unmarked")
	if err := tmuxconfig.Prepare(root); err != nil {
		t.Fatal(err)
	}
	r := tmuxtest.NewRunner(t)
	mustTmux(t, r, "new-session", "-d", "-s", "test", "sleep 60")
	mustTmux(t, r, "set-option", "-s", "exit-empty", "off")
	mustTmux(t, r, "kill-session", "-t", tmux.SessionTarget("test"))
	client := tmux.NewClient(r)
	if _, err := tmuxconfig.Reload(t.Context(), client, root); err == nil || !strings.Contains(err.Error(), "unmarked or belongs to another state root") {
		t.Fatalf("unmarked reload: %v", err)
	}
	if _, err := tmuxconfig.RestartIfEmpty(t.Context(), client, root); err == nil || !strings.Contains(err.Error(), "unmarked or belongs to another state root") {
		t.Fatalf("unmarked restart: %v", err)
	}
	if got := mustTmux(t, r, "show-options", "-gqv", "exit-empty"); got != "off" {
		t.Fatalf("unmarked server stopped or changed: %q", got)
	}
}

func TestIntegrationForeignRootCannotRestartEmptyServer(t *testing.T) {
	tmuxtest.RequireIntegration(t)
	rootA, rootB := t.TempDir(), t.TempDir()
	t.Setenv("HOME", t.TempDir())
	t.Setenv("QUESTMASTER_STATE_ROOT", rootA)
	t.Setenv("QUESTMASTER_TMUX_LABEL", "dev_owned")
	if err := tmuxconfig.Prepare(rootA); err != nil {
		t.Fatal(err)
	}
	paths := tmuxconfig.Paths(rootA)
	r := tmuxtest.NewRunnerWithConfig(t, paths.Config, paths.Enforced)
	mustTmux(t, r, "new-session", "-d", "-s", "test", "sleep 60")
	mustTmux(t, r, "kill-session", "-t", tmux.SessionTarget("test"))
	if _, err := tmuxconfig.RestartIfEmpty(t.Context(), tmux.NewClient(r), rootB); err == nil || !strings.Contains(err.Error(), "unmarked or belongs to another state root") {
		t.Fatalf("foreign restart: %v", err)
	}
	if got := mustTmux(t, r, "show-options", "-gqv", "@questmaster_root"); !tmuxconfig.OwnsRoot(got, rootA, "dev_owned") {
		t.Fatalf("foreign restart changed server: %q", got)
	}
}

func TestIntegrationPrepareAndRestartKeepDetachedSessions(t *testing.T) {
	tmuxtest.RequireIntegration(t)
	r, client, root := configServer(t)
	mustTmux(t, r, "new-session", "-d", "-s", "first", "sleep 60")
	// Prepare regenerates files while the server is running but does not source
	// them. Startup after restart reads user and enforced files before sessions.
	if err := os.WriteFile(tmuxconfig.Paths(root).Config, []byte("set -s exit-empty on\nset -s exit-unattached on\nset -g destroy-unattached on\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := tmuxconfig.Prepare(root); err != nil {
		t.Fatal(err)
	}
	if got := mustTmux(t, r, "list-sessions", "-F", "#{session_name}"); got != "first" {
		t.Fatalf("Prepare changed the running server: %q", got)
	}
	mustTmux(t, r, "kill-session", "-t", tmux.SessionTarget("first"))
	result, err := tmuxconfig.RestartIfEmpty(t.Context(), client, root)
	if err != nil || !result.Restarted {
		t.Fatalf("restart: %+v, %v", result, err)
	}
	mustTmux(t, r, "new-session", "-d", "-s", "second", "sleep 60")
	if got := mustTmux(t, r, "list-sessions", "-F", "#{session_name}"); got != "second" {
		t.Fatalf("session lost after restart: %q", got)
	}
	for _, option := range []string{"destroy-unattached", "exit-unattached", "exit-empty"} {
		if got := mustTmux(t, r, "show-options", "-gqv", option); got != "off" {
			t.Fatalf("%s after restart = %q", option, got)
		}
	}
}

func TestIntegrationReloadRegeneratesMissingLabelFiles(t *testing.T) {
	tmuxtest.RequireIntegration(t)
	r, client, root := configServer(t)
	mustTmux(t, r, "new-session", "-d", "-s", "test", "sleep 60")
	paths := tmuxconfig.Paths(root)
	for _, path := range []string{paths.Enforced, paths.Reload} {
		if err := os.Remove(path); err != nil {
			t.Fatal(err)
		}
	}
	result, err := tmuxconfig.Reload(t.Context(), client, root)
	if err != nil || len(result.Errors) != 0 {
		t.Fatalf("reload after upgrade: %+v, %v", result, err)
	}
	for _, path := range []string{paths.Enforced, paths.Reload} {
		if _, err := os.Stat(path); err != nil {
			t.Fatalf("missing generated file %s: %v", path, err)
		}
	}
	if got := mustTmux(t, r, "list-sessions", "-F", "#{session_name}"); got != "test" {
		t.Fatalf("reload lost session: %q", got)
	}
}
