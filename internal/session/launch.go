package session

import (
	"context"
	"fmt"
	"os"

	"github.com/alexivison/questmaster/internal/agent"
	"github.com/alexivison/questmaster/internal/focus"
	"github.com/alexivison/questmaster/internal/hooks"
	"github.com/alexivison/questmaster/internal/state"
)

const openCodeConfigDirEnv = "OPENCODE_CONFIG_DIR"

// launchConfig captures the resolved parameters for launching a session.
// Both Start and Continue build this from their respective inputs, then
// delegate to launchSession for the shared setup sequence.
type launchConfig struct {
	sessionID   string
	cwd         string
	runtimeDir  string
	title       string
	agentPath   string
	master      bool
	worker      bool
	shell       bool
	agentCmds   map[agent.Role]string
	agents      map[agent.Role]agent.Agent
	agentResume map[agent.Role]resumeInfo
}

type resumeInfo struct {
	provider agent.Agent
	resumeID string
}

// launchSession performs the shared tmux session setup:
// set session env → build commands → persist resume IDs → set resume env →
// choose layout → launch panes → set cleanup hook.
func (s *Service) launchSession(ctx context.Context, lc launchConfig) error {
	openCodeConfigDir := s.openCodeConfigDir(lc.agents)
	if openCodeConfigDir != "" {
		if err := hooks.NewOpenCodeInstaller(openCodeConfigDir).Install(); err != nil {
			return fmt.Errorf("install OpenCode config: %w", err)
		}
	}

	if provider, ok := lc.agents[agent.RolePrimary]; ok {
		if _, hasCmd := lc.agentCmds[agent.RolePrimary]; hasCmd {
			if err := provider.PreLaunchSetup(ctx, s.Client, lc.sessionID); err != nil {
				return err
			}
		}
	}

	if err := s.Client.SetEnvironment(ctx, lc.sessionID, state.SessionEnv, lc.sessionID); err != nil {
		return err
	}
	if lc.agentPath != "" {
		if err := s.Client.SetEnvironment(ctx, lc.sessionID, "PATH", lc.agentPath); err != nil {
			return err
		}
	}
	if openCodeConfigDir != "" {
		if err := s.Client.SetEnvironment(ctx, lc.sessionID, openCodeConfigDirEnv, openCodeConfigDir); err != nil {
			return err
		}
	}
	if err := s.refreshAppOwnedSessionEnvironment(ctx, lc.sessionID); err != nil {
		return err
	}

	if lc.shell {
		if err := s.launchShellWorkspace(ctx, lc.sessionID, lc.cwd); err != nil {
			return err
		}
		return s.setCleanupHook(ctx, lc.sessionID)
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

	if err := s.launchAppWorkspace(ctx, lc.sessionID, lc.cwd, lc.master, lc.worker, lc.agentCmds); err != nil {
		return err
	}

	if err := s.setCleanupHook(ctx, lc.sessionID); err != nil {
		return err
	}

	return nil
}

func (s *Service) openCodeConfigDir(agents map[agent.Role]agent.Agent) string {
	for _, provider := range agents {
		if provider.Name() == "opencode" {
			return state.OpenCodeConfigDir(s.Store.Root())
		}
	}
	return ""
}

func (s *Service) refreshAppOwnedSessionEnvironment(ctx context.Context, sessionID string) error {
	if err := s.Client.UnsetEnvironment(ctx, sessionID, "QUESTMASTER_HOME"); err != nil {
		return err
	}

	// Propagate the resolved state root so hooks installed in the
	// agent's config dir know where to write state.json / state.jsonl.
	if root := state.StateRoot(); root != "" {
		if err := s.Client.SetEnvironment(ctx, sessionID, state.StateRootEnv, root); err != nil {
			return err
		}
	}
	for _, key := range []string{
		"QUESTMASTER_BIN",
		"QUESTMASTER_PATH_PREFIX",
		"QUESTMASTER_APP",
		focus.SocketEnv,
	} {
		if value := os.Getenv(key); value != "" {
			if err := s.Client.SetEnvironment(ctx, sessionID, key, value); err != nil {
				return err
			}
		}
	}
	return nil
}
