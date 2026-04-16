package session

import (
	"context"
	"fmt"

	"github.com/anthropics/ai-party/tools/party-cli/internal/agent"
)

// launchConfig captures the resolved parameters for launching a session.
// Both Start and Continue build this from their respective inputs, then
// delegate to launchSession for the shared setup sequence.
type launchConfig struct {
	sessionID   string
	cwd         string
	runtimeDir  string
	title       string
	agentPath   string
	prompt      string
	master      bool
	worker      bool
	layout      LayoutMode
	agentCmds   map[agent.Role]string
	agents      map[agent.Role]agent.Agent
	agentResume map[agent.Role]resumeInfo
}

type resumeInfo struct {
	provider agent.Agent
	resumeID string
}

// launchSession performs the shared tmux session setup:
// clear env → set PARTY_SESSION → build commands → persist resume IDs →
// set resume env → choose layout → launch panes → set cleanup hook.
func (s *Service) launchSession(ctx context.Context, lc launchConfig) error {
	for _, role := range []agent.Role{agent.RolePrimary, agent.RoleCompanion} {
		provider, ok := lc.agents[role]
		if !ok {
			continue
		}
		if _, ok := lc.agentCmds[role]; !ok {
			continue
		}
		if err := provider.PreLaunchSetup(ctx, s.Client, lc.sessionID); err != nil {
			return err
		}
	}

	if err := s.Client.SetEnvironment(ctx, lc.sessionID, "PARTY_SESSION", lc.sessionID); err != nil {
		return err
	}

	if lc.master {
		if lc.agentCmds[agent.RolePrimary] == "" {
			return fmt.Errorf("primary agent command not configured")
		}
		if err := s.persistResumeIDs(lc.runtimeDir, lc.agentResume); err != nil {
			return err
		}
		if err := s.setResumeEnv(ctx, lc.sessionID, lc.agentResume); err != nil {
			return err
		}
		if err := s.launchMaster(ctx, lc.sessionID, lc.cwd, lc.agentCmds); err != nil {
			return err
		}
	} else {
		layout := lc.layout
		if layout == "" {
			layout = resolveLayout()
		}
		if err := s.Client.SetEnvironment(ctx, lc.sessionID, "PARTY_LAYOUT", string(layout)); err != nil {
			return err
		}

		if lc.agentCmds[agent.RolePrimary] == "" {
			return fmt.Errorf("primary agent command not configured")
		}
		if err := s.persistResumeIDs(lc.runtimeDir, lc.agentResume); err != nil {
			return err
		}
		if err := s.setResumeEnv(ctx, lc.sessionID, lc.agentResume); err != nil {
			return err
		}

		if layout == LayoutSidebar {
			if err := s.launchSidebar(ctx, lc.sessionID, lc.cwd, lc.title, lc.worker, lc.agentCmds); err != nil {
				return err
			}
		} else {
			if err := s.launchClassic(ctx, lc.sessionID, lc.cwd, lc.agentCmds); err != nil {
				return err
			}
		}
	}

	if err := s.setCleanupHook(ctx, lc.sessionID); err != nil {
		return err
	}

	return nil
}
