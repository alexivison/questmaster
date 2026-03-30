package session

import (
	"context"
	"fmt"

	"github.com/anthropics/ai-config/tools/party-cli/internal/state"
	"github.com/anthropics/ai-config/tools/party-cli/internal/tmux"
)

// Promote converts a worker or standalone session to a master session.
// Handles both classic layout (replaces Codex pane) and sidebar layout
// (replaces sidebar pane in window 1; Codex stays in hidden window 0).
func (s *Service) Promote(ctx context.Context, sessionID string) error {
	if !state.IsValidPartyID(sessionID) {
		return fmt.Errorf("invalid session name %q (must start with party-)", sessionID)
	}

	m, err := s.Store.Read(sessionID)
	if err != nil {
		return fmt.Errorf("read manifest: %w", err)
	}
	if m.SessionType == "master" {
		return nil // idempotent
	}

	if err := s.Client.EnsureSessionRunning(ctx, sessionID, "target"); err != nil {
		return err
	}

	// Read layout mode from the tmux session environment
	layout, _, err := s.Client.ShowEnvironment(ctx, sessionID, "PARTY_LAYOUT")
	if err != nil {
		return fmt.Errorf("read layout: %w", err)
	}

	// Set master in manifest BEFORE respawn so party-cli sees correct mode on first render.
	// Clear codex_thread_id — master mode has no Wizard, stale ID confuses the picker.
	newWinName := windowName(m.Title, roleMaster)
	if err := s.Store.Update(sessionID, func(m2 *state.Manifest) {
		m2.SessionType = "master"
		m2.WindowName = newWinName
		delete(m2.Extra, "codex_thread_id")
	}); err != nil {
		return fmt.Errorf("update manifest: %w", err)
	}

	// Clear the tmux env var so shell scripts don't see a stale Codex thread.
	_ = s.Client.UnsetEnvironment(ctx, sessionID, "CODEX_THREAD_ID")

	// Rename the live tmux window to reflect the new master role.
	winIdx := tmux.WindowCodex // classic: single window 0
	if layout == "sidebar" {
		winIdx = tmux.WindowWorkspace
	}
	winTarget := fmt.Sprintf("%s:%d", sessionID, winIdx)
	if err := s.Client.RenameWindow(ctx, winTarget, newWinName); err != nil {
		return fmt.Errorf("rename window: %w", err)
	}

	cliCmd, err := s.resolveCLICmd()
	if err != nil {
		return fmt.Errorf("resolve party-cli: %w", err)
	}

	cwd := m.Cwd
	if cwd == "" {
		cwd = "."
	}

	if layout == "sidebar" {
		return s.promoteSidebar(ctx, sessionID, cwd, cliCmd)
	}
	return s.promoteClassic(ctx, sessionID, cwd, cliCmd)
}

// promoteClassic replaces the Codex pane with the tracker (classic layout).
func (s *Service) promoteClassic(ctx context.Context, sessionID, cwd, cliCmd string) error {
	codexPane, err := s.Client.ResolveRole(ctx, sessionID, "codex", -1)
	if err != nil {
		return fmt.Errorf("find codex pane: %w", err)
	}

	if err := s.Client.RespawnPane(ctx, codexPane, cwd, cliCmd); err != nil {
		return fmt.Errorf("respawn tracker: %w", err)
	}
	if err := s.Client.SetPaneOption(ctx, codexPane, "@party_role", "tracker"); err != nil {
		return err
	}
	return s.Client.SelectPaneTitle(ctx, codexPane, "Tracker")
}

// promoteSidebar replaces the sidebar pane (window 1, pane 0) with the tracker
// and kills the hidden Codex window (window 0) — master mode has no Wizard.
func (s *Service) promoteSidebar(ctx context.Context, sessionID, cwd, cliCmd string) error {
	sidebarTarget := fmt.Sprintf("%s:%d.0", sessionID, tmux.WindowWorkspace)

	if err := s.Client.RespawnPane(ctx, sidebarTarget, cwd, cliCmd); err != nil {
		return fmt.Errorf("respawn tracker in sidebar: %w", err)
	}
	if err := s.Client.SetPaneOption(ctx, sidebarTarget, "@party_role", "tracker"); err != nil {
		return err
	}
	if err := s.Client.SelectPaneTitle(ctx, sidebarTarget, "Tracker"); err != nil {
		return err
	}

	// Kill the hidden Codex window — master mode doesn't use the Wizard.
	codexWindow := fmt.Sprintf("%s:%d", sessionID, tmux.WindowCodex)
	return s.Client.KillWindow(ctx, codexWindow)
}
