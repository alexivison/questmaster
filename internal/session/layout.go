package session

import (
	"context"
	"fmt"
	"os"

	"github.com/alexivison/questmaster/internal/agent"
	"github.com/alexivison/questmaster/internal/tmux"
)

// setPaneOption returns the raw tmux args for set-option -p.
func setPaneOption(target, key, value string) []string {
	return []string{"set-option", "-p", "-t", target, key, value}
}

// setRemainOnExit marks a pane to stay open after its command exits, so the
// agent pane survives an agent crash and can be respawned by Continue.
func (s *Service) setRemainOnExit(ctx context.Context, target string) error {
	return s.Client.SetPaneOption(ctx, target, tmux.PaneRemainOnExit, "on")
}

// launchAppWorkspace sets up the session layout: a single agent pane, the one
// new-session reported. Every target is that pane's ID, so the server's window
// and pane base indexes do not matter.
func (s *Service) launchAppWorkspace(ctx context.Context, agentPane, cwd string, isMaster, isWorker bool, cmds map[agent.Role]string) error {
	label := "session"
	if isMaster {
		label = "master"
	} else if isWorker {
		label = "worker"
	}
	agentCmd := cmds[agent.RoleAgent]
	if agentCmd == "" {
		return fmt.Errorf("%s agent pane: command not configured", label)
	}

	if err := s.setRemainOnExit(ctx, agentPane); err != nil {
		return err
	}

	// A window option and select-window take the pane's ID as its window.
	if _, err := s.Client.RunBatch(ctx,
		setPaneOption(agentPane, tmux.PaneRoleOption, tmux.RoleAgent),
		[]string{"set-option", "-w", "-t", agentPane, tmux.PaneBorderStatusOption, tmux.PaneBorderStatusTop},
		[]string{"select-window", "-t", agentPane},
		[]string{"select-pane", "-t", agentPane},
	); err != nil {
		return fmt.Errorf("%s workspace options batch: %w", label, err)
	}

	if err := s.Client.RespawnPane(ctx, agentPane, cwd, agentCmd); err != nil {
		return fmt.Errorf("%s agent pane: %w", label, err)
	}
	return nil
}

// launchShellWorkspace sets up a plain-terminal session: one pane, the one
// new-session reported, running a login shell.
func (s *Service) launchShellWorkspace(ctx context.Context, pane, cwd string) error {
	if _, err := s.Client.RunBatch(ctx, setPaneOption(pane, tmux.PaneRoleOption, tmux.RoleShell)); err != nil {
		return fmt.Errorf("shell workspace options: %w", err)
	}
	return s.Client.RespawnPane(ctx, pane, cwd, loginShellCommand())
}

func loginShellCommand() string {
	sh := os.Getenv("SHELL")
	if sh == "" {
		sh = "/bin/zsh"
	}
	// exec: RespawnPane puts a cd in front, so the login shell must replace the
	// wrapping sh rather than run as its child.
	return "exec " + sh + " -l"
}
