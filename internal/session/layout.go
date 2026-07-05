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
// primary pane survives an agent crash and can be respawned by Continue.
func (s *Service) setRemainOnExit(ctx context.Context, target string) error {
	return s.Client.SetPaneOption(ctx, target, tmux.PaneRemainOnExit, "on")
}

// launchAppWorkspace sets up the session layout: a single primary pane.
func (s *Service) launchAppWorkspace(ctx context.Context, session, cwd string, isMaster, isWorker bool, cmds map[agent.Role]string) error {
	label := "session"
	if isMaster {
		label = "master"
	} else if isWorker {
		label = "worker"
	}
	primaryCmd := cmds[agent.RolePrimary]
	if primaryCmd == "" {
		return fmt.Errorf("%s primary pane: primary agent command not configured", label)
	}

	workspaceWindow := tmux.WindowTarget(session, tmux.WindowWorkspace)
	primaryPane := tmux.PaneTarget(session, tmux.WindowWorkspace, 0)

	if err := s.setRemainOnExit(ctx, primaryPane); err != nil {
		return err
	}

	if _, err := s.Client.RunBatch(ctx,
		setPaneOption(primaryPane, tmux.PaneRoleOption, tmux.RolePrimary),
		[]string{"set-option", "-w", "-t", workspaceWindow, tmux.PaneBorderStatusOption, tmux.PaneBorderStatusTop},
		[]string{"select-window", "-t", workspaceWindow},
		[]string{"select-pane", "-t", primaryPane},
	); err != nil {
		return fmt.Errorf("%s workspace options batch: %w", label, err)
	}

	if err := s.Client.RespawnPane(ctx, primaryPane, cwd, primaryCmd); err != nil {
		return fmt.Errorf("%s primary pane: %w", label, err)
	}

	return nil
}

// launchShellWorkspace sets up a plain-terminal session: one pane, login shell.
func (s *Service) launchShellWorkspace(ctx context.Context, session, cwd string) error {
	pane := tmux.PaneTarget(session, tmux.WindowWorkspace, 0)
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
	return sh + " -l"
}
