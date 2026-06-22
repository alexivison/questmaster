package session

import (
	"context"
	"fmt"
	"strings"

	"github.com/alexivison/questmaster/internal/agent"
	"github.com/alexivison/questmaster/internal/tmux"
)

const (
	// Canonical pane widths as tmux percentage strings.
	leftPaneWidth       = "16%"
	appPrimaryPaneWidth = "55%"
	shellPaneWidth      = "45%"
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

func paneResizeCmd(leftTarget, leftWidth, shellTarget, shellWidth string) string {
	parts := make([]string, 0, 2)
	if leftTarget != "" {
		parts = append(parts, fmt.Sprintf("tmux resize-pane -t %s -x %s", leftTarget, leftWidth))
	}
	if shellTarget != "" {
		parts = append(parts, fmt.Sprintf("tmux resize-pane -t %s -x %s", shellTarget, shellWidth))
	}
	return strings.Join(parts, " && ")
}

func paneResizeArgs(leftTarget, leftWidth, shellTarget, shellWidth string) [][]string {
	cmds := make([][]string, 0, 2)
	if leftTarget != "" {
		cmds = append(cmds, []string{"resize-pane", "-t", leftTarget, "-x", leftWidth})
	}
	if shellTarget != "" {
		cmds = append(cmds, []string{"resize-pane", "-t", shellTarget, "-x", shellWidth})
	}
	return cmds
}

func layoutRetryCmd(cmd string) string {
	if cmd == "" {
		return ""
	}
	return fmt.Sprintf(`%s; for delay in 0.15 0.35 0.75 1.5 3; do sleep "$delay"; %s; done`, cmd, cmd)
}

func (s *Service) applyInitialPaneResizes(ctx context.Context, leftTarget, leftWidth, shellTarget, shellWidth string) error {
	cmds := paneResizeArgs(leftTarget, leftWidth, shellTarget, shellWidth)
	if len(cmds) == 0 {
		return nil
	}
	_, err := s.Client.RunBatch(ctx, cmds...)
	return err
}

func (s *Service) applyInitialLayoutResizes(ctx context.Context, leftTarget, shellTarget string) error {
	return s.applyInitialPaneResizes(ctx, leftTarget, leftPaneWidth, shellTarget, shellPaneWidth)
}

func (s *Service) applyInitialAppLayoutResizes(ctx context.Context, primaryTarget, shellTarget string) error {
	return s.applyInitialPaneResizes(ctx, primaryTarget, appPrimaryPaneWidth, shellTarget, shellPaneWidth)
}

func (s *Service) applyPaneResizes(ctx context.Context, session, leftTarget, leftWidth, shellTarget, shellWidth string) error {
	cmd := paneResizeCmd(leftTarget, leftWidth, shellTarget, shellWidth)
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

func (s *Service) applyLayoutResizes(ctx context.Context, session, leftTarget, shellTarget string) error {
	return s.applyPaneResizes(ctx, session, leftTarget, leftPaneWidth, shellTarget, shellPaneWidth)
}

func (s *Service) applyAppLayoutResizes(ctx context.Context, session, primaryTarget, shellTarget string) error {
	return s.applyPaneResizes(ctx, session, primaryTarget, appPrimaryPaneWidth, shellTarget, shellPaneWidth)
}

// launchSidebar sets up the single-window 3-pane layout: tracker | primary | shell.
func (s *Service) launchSidebar(ctx context.Context, session, cwd, title string, isWorker bool, cmds map[agent.Role]string) error {
	role := roleStandalone
	if isWorker {
		role = roleWorker
	}
	return s.launchTrackedWorkspace(ctx, session, cwd, windowName(title, role), "sidebar", cmds)
}

// launchMaster sets up the single-window 3-pane layout: tracker | primary | shell.
func (s *Service) launchMaster(ctx context.Context, session, cwd, title string, cmds map[agent.Role]string) error {
	return s.launchTrackedWorkspace(ctx, session, cwd, windowName(title, roleMaster), "master", cmds)
}

// launchAppWorkspace sets up the native-app layout: primary | shell.
func (s *Service) launchAppWorkspace(ctx context.Context, session, cwd, title string, isMaster, isWorker bool, cmds map[agent.Role]string) error {
	role := roleStandalone
	label := "app"
	if isMaster {
		role = roleMaster
		label = "app master"
	} else if isWorker {
		role = roleWorker
		label = "app worker"
	}
	return s.launchAppWorkspaceWithName(ctx, session, cwd, windowName(title, role), label, cmds)
}

func (s *Service) launchAppWorkspaceWithName(ctx context.Context, session, cwd, workspaceName, label string, cmds map[agent.Role]string) error {
	primaryCmd := roleCmd(cmds, agent.RolePrimary)
	if primaryCmd == "" {
		return fmt.Errorf("%s primary pane: primary agent command not configured", label)
	}

	workspaceWindow := tmux.WindowTarget(session, tmux.WindowWorkspace)
	primaryPane := tmux.PaneTarget(session, tmux.WindowWorkspace, 0)
	shellPane := tmux.PaneTarget(session, tmux.WindowWorkspace, 1)

	if err := s.Client.RenameWindow(ctx, workspaceWindow, workspaceName); err != nil {
		return fmt.Errorf("%s workspace window: %w", label, err)
	}
	if err := s.setRemainOnExit(ctx, primaryPane); err != nil {
		return err
	}

	if err := s.Client.SplitWindow(ctx, primaryPane, cwd, "", true, 45); err != nil {
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

	if err := s.applyInitialAppLayoutResizes(ctx, primaryPane, shellPane); err != nil {
		return fmt.Errorf("%s initial resize: %w", label, err)
	}
	if err := s.Client.RespawnPane(ctx, primaryPane, cwd, primaryCmd); err != nil {
		return fmt.Errorf("%s primary pane: %w", label, err)
	}

	return s.applyAppLayoutResizes(ctx, session, primaryPane, shellPane)
}

// launchTrackedWorkspace builds a single workspace window with three side-by-side
// panes: tracker (left, leftPaneWidth) | primary (middle) | shell (right,
// shellPaneWidth). Used for master, standalone, and worker sessions alike.
func (s *Service) launchTrackedWorkspace(ctx context.Context, session, cwd, workspaceName, label string, cmds map[agent.Role]string) error {
	primaryCmd := roleCmd(cmds, agent.RolePrimary)
	if primaryCmd == "" {
		return fmt.Errorf("%s primary pane: primary agent command not configured", label)
	}

	workspaceWindow := tmux.WindowTarget(session, tmux.WindowWorkspace)
	trackerPane := tmux.PaneTarget(session, tmux.WindowWorkspace, 0)
	primaryPane := tmux.PaneTarget(session, tmux.WindowWorkspace, 1)
	shellPane := tmux.PaneTarget(session, tmux.WindowWorkspace, 2)

	cliCmd, err := s.resolveCLICmd()
	if err != nil {
		return fmt.Errorf("resolve questmaster: %w", err)
	}

	if err := s.Client.RenameWindow(ctx, workspaceWindow, workspaceName); err != nil {
		return fmt.Errorf("%s workspace window: %w", label, err)
	}
	if err := s.Client.RespawnPane(ctx, trackerPane, cwd, cliCmd); err != nil {
		return fmt.Errorf("%s tracker pane: %w", label, err)
	}
	// Pin tracker remain-on-exit BEFORE using it as a split target so the
	// pane survives even if the tracker CLI exits during startup.
	if err := s.setRemainOnExit(ctx, trackerPane); err != nil {
		return err
	}

	// Split off the primary pane to the right of the tracker. Pct is the
	// new pane's percentage; tracker keeps 16%, primary+shell take 84%.
	if err := s.Client.SplitWindow(ctx, trackerPane, cwd, "", true, 84); err != nil {
		return fmt.Errorf("%s primary pane: %w", label, err)
	}
	if err := s.setRemainOnExit(ctx, primaryPane); err != nil {
		return err
	}

	// Split the shell off the primary pane. 54% of the 84% remainder gives
	// shell ≈ 45% of total (matching shellPaneWidth).
	if err := s.Client.SplitWindow(ctx, primaryPane, cwd, "", true, 54); err != nil {
		return fmt.Errorf("%s shell pane: %w", label, err)
	}

	if _, err := s.Client.RunBatch(ctx,
		setPaneOption(trackerPane, tmux.PaneRoleOption, tmux.RoleTracker),
		setPaneOption(primaryPane, tmux.PaneRoleOption, tmux.RolePrimary),
		setPaneOption(shellPane, tmux.PaneRoleOption, tmux.RoleShell),
		themeCmd(workspaceWindow),
		[]string{"select-pane", "-t", trackerPane, "-T", "Tracker"},
		[]string{"select-window", "-t", workspaceWindow},
		[]string{"select-pane", "-t", primaryPane},
	); err != nil {
		return fmt.Errorf("%s workspace options batch: %w", label, err)
	}

	// Snap to canonical widths before launching the primary agent so it
	// doesn't paint during resize.
	if err := s.applyInitialLayoutResizes(ctx, trackerPane, shellPane); err != nil {
		return fmt.Errorf("%s initial resize: %w", label, err)
	}
	if err := s.Client.RespawnPane(ctx, primaryPane, cwd, primaryCmd); err != nil {
		return fmt.Errorf("%s primary pane: %w", label, err)
	}

	return s.applyLayoutResizes(ctx, session, trackerPane, shellPane)
}

// Resize resets the pane layout to canonical widths for the given session.
// The standalone layout uses tracker | primary | shell; the app layout uses
// primary | shell, so primary becomes the left resize target when no tracker
// pane exists.
func (s *Service) Resize(ctx context.Context, sessionID string) error {
	panes, err := s.Client.ListPanes(ctx, sessionID)
	if err != nil {
		return fmt.Errorf("list panes: %w", err)
	}

	var trackerTarget, primaryTarget, shellTarget string
	for _, p := range panes {
		switch p.Role {
		case tmux.RoleTracker:
			if trackerTarget == "" {
				trackerTarget = p.Target()
			}
		case tmux.RolePrimary:
			if primaryTarget == "" {
				primaryTarget = p.Target()
			}
		case tmux.RoleShell:
			if shellTarget == "" {
				shellTarget = p.Target()
			}
		}
	}

	leftTarget := trackerTarget
	leftWidth := leftPaneWidth
	if leftTarget == "" {
		leftTarget = primaryTarget
		leftWidth = appPrimaryPaneWidth
	}
	if leftTarget == "" {
		return fmt.Errorf("no tracker or primary pane found in session %s", sessionID)
	}
	if shellTarget == "" {
		return fmt.Errorf("no shell pane found in session %s", sessionID)
	}

	if err := s.Client.ResizePane(ctx, leftTarget, leftWidth); err != nil {
		return err
	}
	return s.Client.ResizePane(ctx, shellTarget, shellPaneWidth)
}
