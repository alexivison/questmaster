package session

import (
	"context"
	"fmt"

	"github.com/alexivison/questmaster/internal/agent"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
)

const promotedMasterRoleMessage = `Questmaster role update: this session is now a master. Orchestrate instead of implementing: create dedicated worktrees for implementation, spawn workers with questmaster spawn --cwd <worktree>, relay scope with questmaster relay, wait for questmaster report without sleep/poll/watch loops, and review worker reports before accepting completion. Use sub-agents only for explicit sub-agent requests; use Questmaster workers for worker, session, or worktree-isolation requests.`

// Promote converts a worker or standalone session to a master session.
func (s *Service) Promote(ctx context.Context, sessionID string) error {
	if err := validateSessionID(sessionID); err != nil {
		return err
	}

	m, err := s.Store.Read(sessionID)
	if err != nil {
		return fmt.Errorf("read manifest: %w", err)
	}
	if len(m.Agents) == 0 {
		return fmt.Errorf("cannot promote %s: plain terminal session has no agent", sessionID)
	}
	if m.SessionType == "master" {
		return nil // idempotent
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

	return s.notifyPromotedMaster(ctx, sessionID)
}

func (s *Service) notifyPromotedMaster(ctx context.Context, sessionID string) error {
	primaryPane, err := s.Client.ResolveRole(ctx, sessionID, string(agent.RolePrimary), -1)
	if err != nil {
		return fmt.Errorf("find primary pane: %w", err)
	}
	result := s.Client.Send(ctx, primaryPane, promotedMasterRoleMessage)
	if result.Err != nil {
		return fmt.Errorf("send master role update to primary: %w", result.Err)
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
