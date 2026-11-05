package agent

import (
	"testing"

	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmux/tmuxtest"
)

// A Claude launch clears CLAUDECODE from its own session only. The global
// environment belongs to every session on the server, so it must survive.
func TestIntegrationClaudeLaunchKeepsGlobalEnv(t *testing.T) {
	t.Parallel()
	tmuxtest.RequireIntegration(t)
	runner := tmuxtest.NewRunner(t)
	const session = "qm-claude-launch"
	run := func(args ...string) string {
		t.Helper()
		out, err := runner.Run(t.Context(), args...)
		if err != nil {
			t.Fatalf("tmux %v: %v", args, err)
		}
		return out
	}
	run("new-session", "-d", "-s", session, "sleep 60")
	run("set-environment", "-g", "CLAUDECODE", "global")
	run("set-environment", "-t", session, "CLAUDECODE", "session")

	if err := NewClaude(AgentConfig{}).PreLaunchSetup(t.Context(), tmux.NewClient(runner), session); err != nil {
		t.Fatalf("PreLaunchSetup: %v", err)
	}

	if got := run("show-environment", "-g", "CLAUDECODE"); got != "CLAUDECODE=global" {
		t.Errorf("global CLAUDECODE = %q, want CLAUDECODE=global", got)
	}
	if out, err := runner.Run(t.Context(), "show-environment", "-t", session, "CLAUDECODE"); err == nil {
		t.Errorf("session CLAUDECODE still set: %q", out)
	}
}
