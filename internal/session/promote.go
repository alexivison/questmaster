package session

import (
	"context"
	"fmt"

	"github.com/anthropics/ai-party/tools/party-cli/internal/agent"
	"github.com/anthropics/ai-party/tools/party-cli/internal/state"
	"github.com/anthropics/ai-party/tools/party-cli/internal/tmux"
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

	registry, err := s.agentRegistry()
	if err != nil {
		return fmt.Errorf("load agent registry: %w", err)
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
	companionEnvVars := companionEnvVars(m, registry)
	if err := s.Store.Update(sessionID, func(m2 *state.Manifest) {
		m2.SessionType = "master"
		m2.WindowName = newWinName
		kept := m2.Agents[:0]
		for _, spec := range m2.Agents {
			if spec.Role != string(agent.RoleCompanion) {
				kept = append(kept, spec)
			}
		}
		m2.Agents = kept
		delete(m2.Extra, "codex_thread_id")
	}); err != nil {
		return fmt.Errorf("update manifest: %w", err)
	}

	for _, envVar := range companionEnvVars {
		_ = s.Client.UnsetEnvironment(ctx, sessionID, envVar)
	}

	// Rename the live tmux window to reflect the new master role.
	winIdx := tmux.WindowCompanion // classic: single window 0
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

	if err := s.injectMasterPrompt(ctx, sessionID, m, registry); err != nil {
		return err
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

func companionEnvVars(m state.Manifest, registry *agent.Registry) []string {
	envVars := make(map[string]struct{})
	for _, spec := range m.Agents {
		if spec.Role != string(agent.RoleCompanion) {
			continue
		}
		if registry != nil {
			if provider, err := registry.Get(spec.Name); err == nil && provider.EnvVar() != "" {
				envVars[provider.EnvVar()] = struct{}{}
				continue
			}
		}
		switch spec.Name {
		case "claude":
			envVars["CLAUDE_SESSION_ID"] = struct{}{}
		case "codex":
			envVars["CODEX_THREAD_ID"] = struct{}{}
		}
	}
	if m.ExtraString("codex_thread_id") != "" {
		envVars["CODEX_THREAD_ID"] = struct{}{}
	}
	out := make([]string, 0, len(envVars))
	for envVar := range envVars {
		out = append(out, envVar)
	}
	return out
}

func (s *Service) injectMasterPrompt(ctx context.Context, sessionID string, m state.Manifest, registry *agent.Registry) error {
	primaryName := ""
	for _, spec := range m.Agents {
		if spec.Role == string(agent.RolePrimary) {
			primaryName = spec.Name
			break
		}
	}
	if primaryName == "" {
		binding, err := registry.ForRole(agent.RolePrimary)
		if err != nil {
			return nil
		}
		primaryName = binding.Agent.Name()
	}

	provider, err := registry.Get(primaryName)
	if err != nil || provider.MasterPrompt() == "" {
		return nil
	}

	primaryPane, err := s.Client.ResolveRole(ctx, sessionID, string(agent.RolePrimary), -1)
	if err != nil {
		return fmt.Errorf("find primary pane: %w", err)
	}
	result := s.Client.Send(ctx, primaryPane, provider.MasterPrompt())
	if result.Err != nil {
		return fmt.Errorf("send master prompt to primary: %w", result.Err)
	}
	return nil
}

// promoteClassic replaces the companion pane with the tracker (classic layout).
func (s *Service) promoteClassic(ctx context.Context, sessionID, cwd, cliCmd string) error {
	companionPane, err := s.Client.ResolveRole(ctx, sessionID, string(agent.RoleCompanion), -1)
	if err != nil {
		return fmt.Errorf("find companion pane: %w", err)
	}

	if err := s.Client.RespawnPane(ctx, companionPane, cwd, cliCmd); err != nil {
		return fmt.Errorf("respawn tracker: %w", err)
	}
	if err := s.Client.SetPaneOption(ctx, companionPane, "@party_role", "tracker"); err != nil {
		return err
	}
	return s.Client.SelectPaneTitle(ctx, companionPane, "Tracker")
}

// promoteSidebar replaces the sidebar pane (window 1, pane 0) with the tracker
// and kills the hidden companion window (window 0) — master mode has no Wizard.
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

	// Kill the hidden companion window — master mode doesn't use the Wizard.
	companionWindow := fmt.Sprintf("%s:%d", sessionID, tmux.WindowCompanion)
	return s.Client.KillWindow(ctx, companionWindow)
}
