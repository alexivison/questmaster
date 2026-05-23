package session

import (
	"context"
	"fmt"
	"strings"

	"github.com/alexivison/questmaster/internal/agent"
	"github.com/alexivison/questmaster/internal/tmux"
)

const (
	dimWindowStyle = "fg=#444444,bg=#1a1a2e"

	// Canonical pane widths as tmux percentage strings.
	leftPaneWidth  = "18%"
	shellPaneWidth = "43%"
)

// setPaneOption returns the raw tmux args for set-option -p.
func setPaneOption(target, key, value string) []string {
	return []string{"set-option", "-p", "-t", target, key, value}
}

// setWindowOption returns the raw tmux args for set-option -w.
func setWindowOption(target, key, value string) []string {
	return []string{"set-option", "-w", "-t", target, key, value}
}

// themeCmd returns the tmux args for the standard theme config.
func themeCmd(target string) []string {
	return setWindowOption(target, tmux.PaneBorderStatusOption, tmux.PaneBorderStatusTop)
}

// setRemainOnExit marks a pane to stay open after its command exits.
// Must be set before the pane is used as a split-window target.
func (s *Service) setRemainOnExit(ctx context.Context, target string) error {
	return s.Client.SetPaneOption(ctx, target, tmux.PaneRemainOnExit, "on")
}

func roleCmd(cmds map[agent.Role]string, role agent.Role) string {
	if cmds == nil {
		return ""
	}
	return cmds[role]
}

func layoutResizeCmd(leftTarget, shellTarget string) string {
	parts := make([]string, 0, 2)
	if leftTarget != "" {
		parts = append(parts, fmt.Sprintf("tmux resize-pane -t %s -x %s", leftTarget, leftPaneWidth))
	}
	if shellTarget != "" {
		parts = append(parts, fmt.Sprintf("tmux resize-pane -t %s -x %s", shellTarget, shellPaneWidth))
	}
	return strings.Join(parts, " && ")
}

func layoutResizeArgs(leftTarget, shellTarget string) [][]string {
	cmds := make([][]string, 0, 2)
	if leftTarget != "" {
		cmds = append(cmds, []string{"resize-pane", "-t", leftTarget, "-x", leftPaneWidth})
	}
	if shellTarget != "" {
		cmds = append(cmds, []string{"resize-pane", "-t", shellTarget, "-x", shellPaneWidth})
	}
	return cmds
}

func layoutRetryCmd(cmd string) string {
	if cmd == "" {
		return ""
	}
	return fmt.Sprintf(`%s; for delay in 0.15 0.35 0.75 1.5 3; do sleep "$delay"; %s; done`, cmd, cmd)
}

func (s *Service) applyInitialLayoutResizes(ctx context.Context, leftTarget, shellTarget string) error {
	cmds := layoutResizeArgs(leftTarget, shellTarget)
	if len(cmds) == 0 {
		return nil
	}
	_, err := s.Client.RunBatch(ctx, cmds...)
	return err
}

func (s *Service) applyLayoutResizes(ctx context.Context, session, leftTarget, shellTarget string) error {
	cmd := layoutResizeCmd(leftTarget, shellTarget)
	if cmd == "" {
		return nil
	}

	if err := s.Client.RunShell(ctx, session, layoutRetryCmd(cmd)); err != nil {
		return err
	}

	hookCmd := fmt.Sprintf(`run-shell -b "%s"`, cmd)
	if err := s.Client.SetHook(ctx, session, "client-attached", hookCmd); err != nil {
		return err
	}
	return s.Client.SetHook(ctx, session, "client-resized", hookCmd)
}

// launchSidebar sets up tracker window 0 and workspace window 1.
func (s *Service) launchSidebar(ctx context.Context, session, cwd, title string, isWorker bool, cmds map[agent.Role]string) error {
	role := roleStandalone
	if isWorker {
		role = roleWorker
	}
	return s.launchTrackedWorkspace(ctx, session, cwd, windowName(title, role), "sidebar", cmds)
}

// launchMaster sets up the master layout: tracker window 0 and workspace window 1.
func (s *Service) launchMaster(ctx context.Context, session, cwd, title string, cmds map[agent.Role]string) error {
	return s.launchTrackedWorkspace(ctx, session, cwd, windowName(title, roleMaster), "master", cmds)
}

func (s *Service) launchTrackedWorkspace(ctx context.Context, session, cwd, workspaceName, label string, cmds map[agent.Role]string) error {
	primaryCmd := roleCmd(cmds, agent.RolePrimary)
	if primaryCmd == "" {
		return fmt.Errorf("%s primary pane: primary agent command not configured", label)
	}

	trackerWindow := tmux.WindowTarget(session, tmux.WindowTracker)
	trackerPane := tmux.PaneTarget(session, tmux.WindowTracker, 0)
	cliCmd, err := s.resolveCLICmd()
	if err != nil {
		return fmt.Errorf("resolve questmaster: %w", err)
	}

	if err := s.Client.RenameWindow(ctx, trackerWindow, "Tracker"); err != nil {
		return fmt.Errorf("%s tracker window: %w", label, err)
	}
	if err := s.Client.RespawnPane(ctx, trackerPane, cwd, cliCmd); err != nil {
		return fmt.Errorf("%s tracker pane: %w", label, err)
	}
	if _, err := s.Client.RunBatch(ctx,
		setPaneOption(trackerPane, tmux.PaneRoleOption, tmux.RoleTracker),
		setPaneOption(trackerPane, tmux.PaneRemainOnExit, "on"),
		themeCmd(trackerWindow),
		[]string{"select-pane", "-t", trackerPane, "-T", "Tracker"},
	); err != nil {
		return fmt.Errorf("%s tracker options batch: %w", label, err)
	}

	if err := s.Client.NewWindow(ctx, session, workspaceName, cwd); err != nil {
		return fmt.Errorf("%s workspace window: %w", label, err)
	}

	workspaceWindow := tmux.WindowTarget(session, tmux.WindowWorkspace)
	primaryPane := tmux.PaneTarget(session, tmux.WindowWorkspace, 0)
	if err := s.setRemainOnExit(ctx, primaryPane); err != nil {
		return err
	}

	shellPane := tmux.PaneTarget(session, tmux.WindowWorkspace, 1)
	if err := s.Client.SplitWindow(ctx, primaryPane, cwd, "", true, 50); err != nil {
		return fmt.Errorf("%s shell pane: %w", label, err)
	}

	if _, err := s.Client.RunBatch(ctx,
		setPaneOption(primaryPane, tmux.PaneRoleOption, tmux.RolePrimary),
		setPaneOption(shellPane, tmux.PaneRoleOption, tmux.RoleShell),
		themeCmd(workspaceWindow),
		[]string{"select-window", "-t", workspaceWindow},
		[]string{"select-pane", "-t", primaryPane},
	); err != nil {
		return fmt.Errorf("%s workspace options batch: %w", label, err)
	}

	if err := s.applyInitialLayoutResizes(ctx, "", shellPane); err != nil {
		return fmt.Errorf("%s initial resize: %w", label, err)
	}
	if err := s.Client.RespawnPane(ctx, primaryPane, cwd, primaryCmd); err != nil {
		return fmt.Errorf("%s primary pane: %w", label, err)
	}

	return s.applyLayoutResizes(ctx, session, "", shellPane)
}

// Resize resets the pane layout to canonical widths for the given session.
// Finds the tracker and shell panes by role, then
// resizes left to leftPaneWidth and shell to shellPaneWidth.
func (s *Service) Resize(ctx context.Context, sessionID string) error {
	panes, err := s.Client.ListPanes(ctx, sessionID)
	if err != nil {
		return fmt.Errorf("list panes: %w", err)
	}

	var leftTarget, shellTarget string
	for _, p := range panes {
		switch p.Role {
		case tmux.RoleTracker:
			if leftTarget == "" {
				leftTarget = p.Target()
			}
		case tmux.RoleShell:
			if shellTarget == "" {
				shellTarget = p.Target()
			}
		}
	}

	if leftTarget == "" {
		return fmt.Errorf("no tracker pane found in session %s", sessionID)
	}
	if shellTarget == "" {
		return fmt.Errorf("no shell pane found in session %s", sessionID)
	}

	if err := s.Client.ResizePane(ctx, leftTarget, leftPaneWidth); err != nil {
		return err
	}
	return s.Client.ResizePane(ctx, shellTarget, shellPaneWidth)
}
