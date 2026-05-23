package session

import (
	"context"
	"fmt"

	"github.com/alexivison/questmaster/internal/agent"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
)

// Promote converts a worker or standalone session to a master session.
func (s *Service) Promote(ctx context.Context, sessionID string) error {
	if err := validateSessionID(sessionID); err != nil {
		return err
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

	// Set master in manifest before notifying the primary so subsequent reads
	// see the new orchestration mode immediately.
	newWinName := windowName(m.Title, roleMaster)
	if err := s.Store.Update(sessionID, func(m2 *state.Manifest) {
		m2.SessionType = "master"
		m2.WindowName = newWinName
	}); err != nil {
		return fmt.Errorf("update manifest: %w", err)
	}

	winTarget := tmux.WindowTarget(sessionID, primaryWindowIndex(ctx, s.Client, sessionID))
	if err := s.Client.RenameWindow(ctx, winTarget, newWinName); err != nil {
		return fmt.Errorf("rename window: %w", err)
	}

	return s.injectMasterPrompt(ctx, sessionID, m, registry)
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

func primaryWindowIndex(ctx context.Context, client *tmux.Client, sessionID string) int {
	panes, err := client.ListPanes(ctx, sessionID)
	if err != nil {
		return tmux.WindowWorkspace
	}
	for _, p := range panes {
		if p.Role == tmux.RolePrimary {
			return p.WindowIndex
		}
	}
	return tmux.WindowWorkspace
}
