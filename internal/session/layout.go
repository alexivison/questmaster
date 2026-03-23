package session

import (
	"context"
	"fmt"
)

const (
	borderFormatTpl = ` #{pane_title} `
	masterBorderFg  = "fg=#ffd700"
	dimWindowStyle  = "fg=#444444,bg=#1a1a2e"
)

// configureTheme sets pane border format for a window target.
func (s *Service) configureTheme(ctx context.Context, target string) error {
	if err := s.Client.SetWindowOption(ctx, target, "pane-border-status", "top"); err != nil {
		return err
	}
	return s.Client.SetWindowOption(ctx, target, "pane-border-format", borderFormatTpl)
}

// launchClassic sets up the single-window layout: Codex | Claude | Shell.
func (s *Service) launchClassic(ctx context.Context, session, cwd, codexCmd, claudeCmd string) error {
	p0 := fmt.Sprintf("%s:0.0", session)

	if err := s.Client.RespawnPane(ctx, p0, cwd, codexCmd); err != nil {
		return fmt.Errorf("classic codex pane: %w", err)
	}
	if err := s.Client.SetPaneOption(ctx, p0, "@party_role", "codex"); err != nil {
		return err
	}
	if err := s.Client.SetPaneOption(ctx, p0, "remain-on-exit", "on"); err != nil {
		return err
	}

	p1 := fmt.Sprintf("%s:0.1", session)
	if err := s.Client.SplitWindow(ctx, p0, cwd, claudeCmd, true, 80); err != nil { // codex 20%, claude+shell 80%
		return fmt.Errorf("classic claude pane: %w", err)
	}
	if err := s.Client.SetPaneOption(ctx, p1, "@party_role", "claude"); err != nil {
		return err
	}
	if err := s.Client.SetPaneOption(ctx, p1, "remain-on-exit", "on"); err != nil {
		return err
	}

	p2 := fmt.Sprintf("%s:0.2", session)
	if err := s.Client.SplitWindow(ctx, p1, cwd, "", true, 44); err != nil { // shell 35% of total
		return fmt.Errorf("classic shell pane: %w", err)
	}
	if err := s.Client.SetPaneOption(ctx, p2, "@party_role", "shell"); err != nil {
		return err
	}

	if err := s.Client.SelectPaneTitle(ctx, p0, "The Wizard"); err != nil {
		return err
	}
	if err := s.Client.SelectPaneTitle(ctx, p1, "The Paladin"); err != nil {
		return err
	}
	if err := s.Client.SelectPaneTitle(ctx, p2, "Shell"); err != nil {
		return err
	}
	if err := s.configureTheme(ctx, session); err != nil {
		return err
	}
	if err := s.Client.SelectPane(ctx, p1); err != nil {
		return err
	}
	resizeCmd := fmt.Sprintf("sleep 1 && tmux resize-pane -t %s -x 20%% && tmux resize-pane -t %s -x 35%%", p0, p2)
	return s.Client.RunShell(ctx, session, resizeCmd)
}

// launchSidebar sets up the dual-window layout:
// Window 0 (hidden): Codex
// Window 1 (active): party-cli | Claude | Shell
func (s *Service) launchSidebar(ctx context.Context, session, cwd, codexCmd, claudeCmd, title string) error {
	w0p0 := fmt.Sprintf("%s:0.0", session)
	w0 := fmt.Sprintf("%s:0", session)

	if err := s.Client.RenameWindow(ctx, w0, "The Wizard"); err != nil {
		return err
	}
	if err := s.Client.RespawnPane(ctx, w0p0, cwd, codexCmd); err != nil {
		return fmt.Errorf("sidebar codex pane: %w", err)
	}
	if err := s.Client.SetPaneOption(ctx, w0p0, "@party_role", "codex"); err != nil {
		return err
	}
	if err := s.Client.SetPaneOption(ctx, w0p0, "remain-on-exit", "on"); err != nil {
		return err
	}
	if err := s.Client.SetWindowOption(ctx, w0, "window-status-style", dimWindowStyle); err != nil {
		return err
	}

	winName := windowName(title)
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
	if err := s.Client.SetPaneOption(ctx, w1p0, "@party_role", "sidebar"); err != nil {
		return err
	}

	// Pane 1: Claude
	w1p1 := fmt.Sprintf("%s:1.1", session)
	if err := s.Client.SplitWindow(ctx, w1p0, cwd, claudeCmd, true, 80); err != nil {
		return fmt.Errorf("sidebar claude pane: %w", err)
	}
	if err := s.Client.SetPaneOption(ctx, w1p1, "@party_role", "claude"); err != nil {
		return err
	}
	if err := s.Client.SetPaneOption(ctx, w1p1, "remain-on-exit", "on"); err != nil {
		return err
	}

	// Pane 2: Shell
	w1p2 := fmt.Sprintf("%s:1.2", session)
	if err := s.Client.SplitWindow(ctx, w1p1, cwd, "", true, 44); err != nil { // shell 35% of total (44% of remaining 80%)
		return fmt.Errorf("sidebar shell pane: %w", err)
	}
	if err := s.Client.SetPaneOption(ctx, w1p2, "@party_role", "shell"); err != nil {
		return err
	}

	if err := s.Client.SelectPaneTitle(ctx, w1p0, "Sidebar"); err != nil {
		return err
	}
	if err := s.Client.SelectPaneTitle(ctx, w1p1, "The Paladin"); err != nil {
		return err
	}
	if err := s.Client.SelectPaneTitle(ctx, w1p2, "Shell"); err != nil {
		return err
	}

	w1 := fmt.Sprintf("%s:1", session)
	if err := s.configureTheme(ctx, w1); err != nil {
		return err
	}
	if err := s.Client.SelectWindow(ctx, w1); err != nil {
		return err
	}
	if err := s.Client.SelectPane(ctx, w1p1); err != nil {
		return err
	}
	// Deferred resize — immediate resize gets overridden by agent startup.
	// run-shell with sleep ensures it fires after everything settles.
	resizeCmd := fmt.Sprintf("sleep 1 && tmux resize-pane -t %s -x 20%% && tmux resize-pane -t %s -x 35%%", w1p0, w1p2)
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
	if err := s.Client.SetPaneOption(ctx, p0, "@party_role", "tracker"); err != nil {
		return err
	}

	p1 := fmt.Sprintf("%s:0.1", session)
	if err := s.Client.SplitWindow(ctx, p0, cwd, claudeCmd, true, 80); err != nil { // tracker 20%, claude+shell 80%
		return fmt.Errorf("master claude pane: %w", err)
	}
	if err := s.Client.SetPaneOption(ctx, p1, "@party_role", "claude"); err != nil {
		return err
	}

	p2 := fmt.Sprintf("%s:0.2", session)
	if err := s.Client.SplitWindow(ctx, p1, cwd, "", true, 44); err != nil { // shell 35% of total
		return fmt.Errorf("master shell pane: %w", err)
	}
	if err := s.Client.SetPaneOption(ctx, p2, "@party_role", "shell"); err != nil {
		return err
	}

	if err := s.Client.SelectPaneTitle(ctx, p0, "Tracker"); err != nil {
		return err
	}
	if err := s.Client.SelectPaneTitle(ctx, p1, "The Paladin"); err != nil {
		return err
	}
	if err := s.Client.SelectPaneTitle(ctx, p2, "Shell"); err != nil {
		return err
	}

	w0 := fmt.Sprintf("%s:0", session)
	if err := s.configureTheme(ctx, w0); err != nil {
		return err
	}
	if err := s.Client.SetSessionOption(ctx, session, "pane-active-border-style", masterBorderFg); err != nil {
		return err
	}
	if err := s.Client.SelectPane(ctx, p1); err != nil {
		return err
	}
	resizeCmd := fmt.Sprintf("sleep 1 && tmux resize-pane -t %s -x 20%% && tmux resize-pane -t %s -x 35%%", p0, p2)
	return s.Client.RunShell(ctx, session, resizeCmd)
}
