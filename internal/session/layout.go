package session

import (
	"context"
	"fmt"
	"strings"

	"github.com/anthropics/ai-party/tools/party-cli/internal/agent"
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
	return setWindowOption(target, "pane-border-status", "top")
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

func layoutRetryCmd(cmd string) string {
	if cmd == "" {
		return ""
	}
	return fmt.Sprintf(`%s; for delay in 0.15 0.35 0.75 1.5 3; do sleep "$delay"; %s; done`, cmd, cmd)
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

// launchClassic sets up the single-window layout: Companion | Primary | Shell.
func (s *Service) launchClassic(ctx context.Context, session, cwd string, cmds map[agent.Role]string) error {
	primaryCmd := roleCmd(cmds, agent.RolePrimary)
	if primaryCmd == "" {
		return fmt.Errorf("classic primary pane: primary agent command not configured")
	}
	companionCmd := roleCmd(cmds, agent.RoleCompanion)
	p0 := fmt.Sprintf("%s:0.0", session)

	if companionCmd == "" {
		if err := s.Client.RespawnPane(ctx, p0, cwd, primaryCmd); err != nil {
			return fmt.Errorf("classic primary pane: %w", err)
		}
		// remain-on-exit before p0 is used as a split target.
		if err := s.Client.SetPaneOption(ctx, p0, "remain-on-exit", "on"); err != nil {
			return err
		}

		p1 := fmt.Sprintf("%s:0.1", session)
		if err := s.Client.SplitWindow(ctx, p0, cwd, "", true, 43); err != nil {
			return fmt.Errorf("classic shell pane: %w", err)
		}

		if _, err := s.Client.RunBatch(ctx,
			setPaneOption(p0, "@party_role", "primary"),
			setPaneOption(p1, "@party_role", "shell"),
			themeCmd(session),
			[]string{"select-pane", "-t", p0},
		); err != nil {
			return fmt.Errorf("classic options batch: %w", err)
		}

		return s.applyLayoutResizes(ctx, session, "", p1)
	}

	if err := s.Client.RespawnPane(ctx, p0, cwd, companionCmd); err != nil {
		return fmt.Errorf("classic companion pane: %w", err)
	}
	// remain-on-exit before p0 is used as a split target.
	if err := s.Client.SetPaneOption(ctx, p0, "remain-on-exit", "on"); err != nil {
		return err
	}

	p1 := fmt.Sprintf("%s:0.1", session)
	if err := s.Client.SplitWindow(ctx, p0, cwd, primaryCmd, true, 82); err != nil { // companion 15%, primary+shell 85%
		return fmt.Errorf("classic primary pane: %w", err)
	}
	// remain-on-exit before p1 is used as a split target.
	if err := s.Client.SetPaneOption(ctx, p1, "remain-on-exit", "on"); err != nil {
		return err
	}

	p2 := fmt.Sprintf("%s:0.2", session)
	if err := s.Client.SplitWindow(ctx, p1, cwd, "", true, 50); err != nil { // shell 43% of total (50% of remaining 85%)
		return fmt.Errorf("classic shell pane: %w", err)
	}

	// Batch remaining pane metadata, theme, and focus.
	if _, err := s.Client.RunBatch(ctx,
		setPaneOption(p0, "@party_role", "companion"),
		setPaneOption(p1, "@party_role", "primary"),
		setPaneOption(p2, "@party_role", "shell"),
		themeCmd(session),
		[]string{"select-pane", "-t", p1},
	); err != nil {
		return fmt.Errorf("classic options batch: %w", err)
	}

	return s.applyLayoutResizes(ctx, session, p0, p2)
}

// launchSidebar sets up the dual-window layout:
// Window 0 (hidden, optional): Companion
// Workspace window: tracker | primary | shell
func (s *Service) launchSidebar(ctx context.Context, session, cwd, title string, isWorker bool, cmds map[agent.Role]string) error {
	primaryCmd := roleCmd(cmds, agent.RolePrimary)
	if primaryCmd == "" {
		return fmt.Errorf("sidebar primary pane: primary agent command not configured")
	}
	companionCmd := roleCmd(cmds, agent.RoleCompanion)
	role := roleStandalone
	if isWorker {
		role = roleWorker
	}
	winName := windowName(title, role)

	workspaceIdx := 0
	if companionCmd != "" {
		w0p0 := fmt.Sprintf("%s:0.0", session)
		w0 := fmt.Sprintf("%s:0", session)

		if err := s.Client.RenameWindow(ctx, w0, "Companion"); err != nil {
			return err
		}
		if err := s.Client.RespawnPane(ctx, w0p0, cwd, companionCmd); err != nil {
			return fmt.Errorf("sidebar companion pane: %w", err)
		}

		// Batch window-0 options (w0p0 is not split, safe to defer).
		if _, err := s.Client.RunBatch(ctx,
			setPaneOption(w0p0, "@party_role", "companion"),
			setPaneOption(w0p0, "remain-on-exit", "on"),
			setWindowOption(w0, "window-status-style", dimWindowStyle),
		); err != nil {
			return fmt.Errorf("sidebar w0 options batch: %w", err)
		}

		if err := s.Client.NewWindow(ctx, session, winName, cwd); err != nil {
			return fmt.Errorf("sidebar workspace window: %w", err)
		}
		workspaceIdx = 1
	}

	// Pane 0: tracker / sidebar CLI
	workspaceWindow := fmt.Sprintf("%s:%d", session, workspaceIdx)
	w1p0 := fmt.Sprintf("%s:%d.0", session, workspaceIdx)
	cliCmd, err := s.resolveCLICmd()
	if err != nil {
		return fmt.Errorf("resolve party-cli: %w", err)
	}
	if err := s.Client.RespawnPane(ctx, w1p0, cwd, cliCmd); err != nil {
		return fmt.Errorf("sidebar cli pane: %w", err)
	}

	// Pane 1: primary agent
	w1p1 := fmt.Sprintf("%s:%d.1", session, workspaceIdx)
	if err := s.Client.SplitWindow(ctx, w1p0, cwd, primaryCmd, true, 82); err != nil {
		return fmt.Errorf("sidebar primary pane: %w", err)
	}
	// remain-on-exit before w1p1 is used as a split target.
	if err := s.Client.SetPaneOption(ctx, w1p1, "remain-on-exit", "on"); err != nil {
		return err
	}

	// Pane 2: Shell
	w1p2 := fmt.Sprintf("%s:%d.2", session, workspaceIdx)
	if err := s.Client.SplitWindow(ctx, w1p1, cwd, "", true, 50); err != nil { // shell 43% of total (50% of remaining 85%)
		return fmt.Errorf("sidebar shell pane: %w", err)
	}

	// Batch remaining window-1 options, theme, and focus.
	if _, err := s.Client.RunBatch(ctx,
		setPaneOption(w1p0, "@party_role", "tracker"),
		setPaneOption(w1p1, "@party_role", "primary"),
		setPaneOption(w1p2, "@party_role", "shell"),
		themeCmd(workspaceWindow),
		[]string{"select-pane", "-t", w1p0, "-T", "Tracker"},
		[]string{"select-window", "-t", workspaceWindow},
		[]string{"select-pane", "-t", w1p1},
	); err != nil {
		return fmt.Errorf("sidebar w1 options batch: %w", err)
	}

	// Deferred resize — immediate resize gets overridden by agent startup.
	return s.applyLayoutResizes(ctx, session, w1p0, w1p2)
}

// launchMaster sets up the master layout: Tracker | Primary | Shell.
func (s *Service) launchMaster(ctx context.Context, session, cwd string, cmds map[agent.Role]string) error {
	primaryCmd := roleCmd(cmds, agent.RolePrimary)
	if primaryCmd == "" {
		return fmt.Errorf("master primary pane: primary agent command not configured")
	}
	companionCmd := roleCmd(cmds, agent.RoleCompanion)
	p0 := fmt.Sprintf("%s:0.0", session)

	cliCmd, err := s.resolveCLICmd()
	if err != nil {
		return fmt.Errorf("resolve party-cli: %w", err)
	}

	if err := s.Client.RespawnPane(ctx, p0, cwd, cliCmd); err != nil {
		return fmt.Errorf("master tracker pane: %w", err)
	}

	p1 := fmt.Sprintf("%s:0.1", session)
	if err := s.Client.SplitWindow(ctx, p0, cwd, primaryCmd, true, 82); err != nil { // tracker 15%, primary+shell 85%
		return fmt.Errorf("master primary pane: %w", err)
	}

	p2 := fmt.Sprintf("%s:0.2", session)
	if err := s.Client.SplitWindow(ctx, p1, cwd, "", true, 50); err != nil { // shell 43% of total (50% of remaining 85%)
		return fmt.Errorf("master shell pane: %w", err)
	}

	// Batch all pane options, theme, and focus.
	w0 := fmt.Sprintf("%s:0", session)
	if _, err := s.Client.RunBatch(ctx,
		setPaneOption(p0, "@party_role", "tracker"),
		setPaneOption(p1, "@party_role", "primary"),
		setPaneOption(p2, "@party_role", "shell"),
		themeCmd(w0),
		[]string{"select-pane", "-t", p0, "-T", "Tracker"},
		[]string{"select-pane", "-t", p1},
	); err != nil {
		return fmt.Errorf("master options batch: %w", err)
	}

	if companionCmd != "" {
		w1 := fmt.Sprintf("%s:1", session)
		if err := s.Client.NewWindow(ctx, session, "Companion", cwd); err != nil {
			return fmt.Errorf("master companion window: %w", err)
		}

		w1p0 := fmt.Sprintf("%s:1.0", session)
		if err := s.Client.RespawnPane(ctx, w1p0, cwd, companionCmd); err != nil {
			return fmt.Errorf("master companion pane: %w", err)
		}

		if _, err := s.Client.RunBatch(ctx,
			setPaneOption(w1p0, "@party_role", "companion"),
			setPaneOption(w1p0, "remain-on-exit", "on"),
			setWindowOption(w1, "window-status-style", dimWindowStyle),
			[]string{"select-window", "-t", w0},
			[]string{"select-pane", "-t", p1},
		); err != nil {
			return fmt.Errorf("master companion options batch: %w", err)
		}
	}

	return s.applyLayoutResizes(ctx, session, p0, p2)
}

// Resize resets the pane layout to canonical widths for the given session.
// Finds the left pane (tracker, companion, or legacy equivalents) and shell pane by role,
// then resizes left to leftPaneWidth and shell to shellPaneWidth.
func (s *Service) Resize(ctx context.Context, sessionID string) error {
	panes, err := s.Client.ListPanes(ctx, sessionID)
	if err != nil {
		return fmt.Errorf("list panes: %w", err)
	}

	var leftRole, leftTarget, shellTarget string
	leftTargets := make(map[string]string, 5)
	for _, p := range panes {
		switch p.Role {
		case "tracker", "sidebar", "companion", "codex", "primary":
			if _, ok := leftTargets[p.Role]; !ok {
				leftTargets[p.Role] = p.Target()
			}
		case "shell":
			if shellTarget == "" {
				shellTarget = p.Target()
			}
		}
	}

	for _, role := range []string{"tracker", "sidebar", "companion", "codex", "primary"} {
		if target := leftTargets[role]; target != "" {
			leftRole = role
			leftTarget = target
			break
		}
	}

	if leftRole == "primary" && len(panes) == 2 {
		return fmt.Errorf("no left pane found (2-pane layout) in session %s", sessionID)
	}
	if leftTarget == "" {
		return fmt.Errorf("no left pane (tracker/sidebar/companion/codex/primary) found in session %s", sessionID)
	}
	if shellTarget == "" {
		return fmt.Errorf("no shell pane found in session %s", sessionID)
	}

	if err := s.Client.ResizePane(ctx, leftTarget, leftPaneWidth); err != nil {
		return err
	}
	return s.Client.ResizePane(ctx, shellTarget, shellPaneWidth)
}
