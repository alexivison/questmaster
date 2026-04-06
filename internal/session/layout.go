package session

import (
	"context"
	"fmt"
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
	return setWindowOption(target, "pane-border-status", "off")
}

// launchClassic sets up the single-window layout: Wizard | Claude | Shell.
func (s *Service) launchClassic(ctx context.Context, session, cwd, codexCmd, claudeCmd string) error {
	p0 := fmt.Sprintf("%s:0.0", session)

	if err := s.Client.RespawnPane(ctx, p0, cwd, codexCmd); err != nil {
		return fmt.Errorf("classic codex pane: %w", err)
	}
	// remain-on-exit before p0 is used as a split target.
	if err := s.Client.SetPaneOption(ctx, p0, "remain-on-exit", "on"); err != nil {
		return err
	}

	p1 := fmt.Sprintf("%s:0.1", session)
	if err := s.Client.SplitWindow(ctx, p0, cwd, claudeCmd, true, 82); err != nil { // codex 15%, claude+shell 85%
		return fmt.Errorf("classic claude pane: %w", err)
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
		setPaneOption(p0, "@party_role", "codex"),
		setPaneOption(p1, "@party_role", "claude"),
		setPaneOption(p2, "@party_role", "shell"),
		themeCmd(session),
		[]string{"select-pane", "-t", p1},
	); err != nil {
		return fmt.Errorf("classic options batch: %w", err)
	}

	resizeCmd := fmt.Sprintf("sleep 0.3 && tmux resize-pane -t %s -x %s && tmux resize-pane -t %s -x %s", p0, leftPaneWidth, p2, shellPaneWidth)
	return s.Client.RunShell(ctx, session, resizeCmd)
}

// launchSidebar sets up the dual-window layout:
// Window 0 (hidden): Codex
// Window 1 (active): party-cli | Claude | Shell
func (s *Service) launchSidebar(ctx context.Context, session, cwd, codexCmd, claudeCmd, title string, isWorker bool) error {
	w0p0 := fmt.Sprintf("%s:0.0", session)
	w0 := fmt.Sprintf("%s:0", session)

	if err := s.Client.RenameWindow(ctx, w0, "The Wizard"); err != nil {
		return err
	}
	if err := s.Client.RespawnPane(ctx, w0p0, cwd, codexCmd); err != nil {
		return fmt.Errorf("sidebar codex pane: %w", err)
	}

	// Batch window-0 options (w0p0 is not split, safe to defer).
	if _, err := s.Client.RunBatch(ctx,
		setPaneOption(w0p0, "@party_role", "codex"),
		setPaneOption(w0p0, "remain-on-exit", "on"),
		setWindowOption(w0, "window-status-style", dimWindowStyle),
	); err != nil {
		return fmt.Errorf("sidebar w0 options batch: %w", err)
	}

	role := roleStandalone
	if isWorker {
		role = roleWorker
	}
	winName := windowName(title, role)
	if err := s.Client.NewWindow(ctx, session, winName, cwd); err != nil {
		return fmt.Errorf("sidebar workspace window: %w", err)
	}

	// Pane 0: party-cli sidebar
	w1p0 := fmt.Sprintf("%s:1.0", session)
	cliCmd, err := s.resolveCLICmd()
	if err != nil {
		return fmt.Errorf("resolve party-cli: %w", err)
	}
	if err := s.Client.RespawnPane(ctx, w1p0, cwd, cliCmd); err != nil {
		return fmt.Errorf("sidebar cli pane: %w", err)
	}

	// Pane 1: Claude
	w1p1 := fmt.Sprintf("%s:1.1", session)
	if err := s.Client.SplitWindow(ctx, w1p0, cwd, claudeCmd, true, 82); err != nil {
		return fmt.Errorf("sidebar claude pane: %w", err)
	}
	// remain-on-exit before w1p1 is used as a split target.
	if err := s.Client.SetPaneOption(ctx, w1p1, "remain-on-exit", "on"); err != nil {
		return err
	}

	// Pane 2: Shell
	w1p2 := fmt.Sprintf("%s:1.2", session)
	if err := s.Client.SplitWindow(ctx, w1p1, cwd, "", true, 50); err != nil { // shell 43% of total (50% of remaining 85%)
		return fmt.Errorf("sidebar shell pane: %w", err)
	}

	// Batch remaining window-1 options, theme, and focus.
	w1 := fmt.Sprintf("%s:1", session)
	if _, err := s.Client.RunBatch(ctx,
		setPaneOption(w1p0, "@party_role", "sidebar"),
		setPaneOption(w1p1, "@party_role", "claude"),
		setPaneOption(w1p2, "@party_role", "shell"),
		themeCmd(w1),
		[]string{"select-window", "-t", w1},
		[]string{"select-pane", "-t", w1p1},
	); err != nil {
		return fmt.Errorf("sidebar w1 options batch: %w", err)
	}

	// Deferred resize — immediate resize gets overridden by agent startup.
	resizeCmd := fmt.Sprintf("sleep 0.3 && tmux resize-pane -t %s -x %s && tmux resize-pane -t %s -x %s", w1p0, leftPaneWidth, w1p2, shellPaneWidth)
	return s.Client.RunShell(ctx, session, resizeCmd)
}

// launchMaster sets up the master layout: Tracker | Claude | Shell.
func (s *Service) launchMaster(ctx context.Context, session, cwd, claudeCmd string) error {
	p0 := fmt.Sprintf("%s:0.0", session)

	cliCmd, err := s.resolveCLICmd()
	if err != nil {
		return fmt.Errorf("resolve party-cli: %w", err)
	}

	if err := s.Client.RespawnPane(ctx, p0, cwd, cliCmd); err != nil {
		return fmt.Errorf("master tracker pane: %w", err)
	}

	p1 := fmt.Sprintf("%s:0.1", session)
	if err := s.Client.SplitWindow(ctx, p0, cwd, claudeCmd, true, 82); err != nil { // tracker 15%, claude+shell 85%
		return fmt.Errorf("master claude pane: %w", err)
	}

	p2 := fmt.Sprintf("%s:0.2", session)
	if err := s.Client.SplitWindow(ctx, p1, cwd, "", true, 50); err != nil { // shell 43% of total (50% of remaining 85%)
		return fmt.Errorf("master shell pane: %w", err)
	}

	// Batch all pane options, theme, and focus.
	w0 := fmt.Sprintf("%s:0", session)
	if _, err := s.Client.RunBatch(ctx,
		setPaneOption(p0, "@party_role", "tracker"),
		setPaneOption(p1, "@party_role", "claude"),
		setPaneOption(p2, "@party_role", "shell"),
		themeCmd(w0),
		[]string{"select-pane", "-t", p1},
	); err != nil {
		return fmt.Errorf("master options batch: %w", err)
	}

	resizeCmd := fmt.Sprintf("sleep 0.3 && tmux resize-pane -t %s -x %s && tmux resize-pane -t %s -x %s", p0, leftPaneWidth, p2, shellPaneWidth)
	return s.Client.RunShell(ctx, session, resizeCmd)
}

// Resize resets the pane layout to canonical widths for the given session.
// Finds the left pane (sidebar, tracker, or codex) and shell pane by role,
// then resizes left to leftPaneWidth and shell to shellPaneWidth.
func (s *Service) Resize(ctx context.Context, sessionID string) error {
	panes, err := s.Client.ListPanes(ctx, sessionID)
	if err != nil {
		return fmt.Errorf("list panes: %w", err)
	}

	var leftTarget, shellTarget string
	for _, p := range panes {
		switch p.Role {
		case "sidebar", "tracker", "codex":
			if leftTarget == "" {
				leftTarget = p.Target()
			}
		case "shell":
			if shellTarget == "" {
				shellTarget = p.Target()
			}
		}
	}

	if leftTarget == "" {
		return fmt.Errorf("no left pane (sidebar/tracker/codex) found in session %s", sessionID)
	}
	if shellTarget == "" {
		return fmt.Errorf("no shell pane found in session %s", sessionID)
	}

	if err := s.Client.ResizePane(ctx, leftTarget, leftPaneWidth); err != nil {
		return err
	}
	return s.Client.ResizePane(ctx, shellTarget, shellPaneWidth)
}
