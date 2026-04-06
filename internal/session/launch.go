package session

import (
	"context"
	"fmt"

	"github.com/anthropics/ai-party/tools/party-cli/internal/config"
)

// launchConfig captures the resolved parameters for launching a session.
// Both Start and Continue build this from their respective inputs, then
// delegate to launchSession for the shared setup sequence.
type launchConfig struct {
	sessionID      string
	cwd            string
	runtimeDir     string
	title          string
	claudeBin      string
	codexBin       string
	agentPath      string
	claudeResumeID string
	codexResumeID  string
	prompt         string
	master         bool
	worker         bool
	layout         LayoutMode
}

// launchSession performs the shared tmux session setup:
// clear env → set PARTY_SESSION → build commands → persist resume IDs →
// set resume env → choose layout → launch panes → set cleanup hook.
func (s *Service) launchSession(ctx context.Context, lc launchConfig) error {
	if err := s.clearClaudeCodeEnv(ctx, lc.sessionID); err != nil {
		return err
	}

	if err := s.Client.SetEnvironment(ctx, lc.sessionID, "PARTY_SESSION", lc.sessionID); err != nil {
		return err
	}

	if lc.master {
		claudeCmd := buildClaudeCmd(lc.claudeBin, lc.agentPath, lc.claudeResumeID, lc.prompt, lc.title)
		if err := s.persistResumeIDs(lc.sessionID, lc.runtimeDir, lc.claudeResumeID, ""); err != nil {
			return err
		}
		if err := s.setResumeEnv(ctx, lc.sessionID, lc.claudeResumeID, ""); err != nil {
			return err
		}
		if err := s.launchMaster(ctx, lc.sessionID, lc.cwd, claudeCmd); err != nil {
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

		claudeCmd := buildClaudeCmd(lc.claudeBin, lc.agentPath, lc.claudeResumeID, lc.prompt, lc.title)
		codexCmd := buildCodexCmd(lc.codexBin, lc.agentPath, lc.codexResumeID)
		if err := s.persistResumeIDs(lc.sessionID, lc.runtimeDir, lc.claudeResumeID, lc.codexResumeID); err != nil {
			return err
		}
		if err := s.setResumeEnv(ctx, lc.sessionID, lc.claudeResumeID, lc.codexResumeID); err != nil {
			return err
		}

		if layout == LayoutSidebar {
			if err := s.launchSidebar(ctx, lc.sessionID, lc.cwd, codexCmd, claudeCmd, lc.title, lc.worker); err != nil {
				return err
			}
		} else {
			if err := s.launchClassic(ctx, lc.sessionID, lc.cwd, codexCmd, claudeCmd); err != nil {
				return err
			}
		}
	}

	if err := s.setCleanupHook(ctx, lc.sessionID); err != nil {
		return err
	}

	return s.sendDeferredRename(ctx, lc.sessionID, lc.title)
}

// sendDeferredRename sends /rename to the Claude pane after a delay so the
// input box picks up the session name and color. The --name CLI flag sets
// metadata but doesn't trigger the visual display; /rename does.
func (s *Service) sendDeferredRename(ctx context.Context, session, title string) error {
	if title == "" {
		return nil
	}
	// Find the claude pane by @party_role, then send /rename.
	// 5s delay lets Claude finish initializing before we inject input.
	cmd := fmt.Sprintf(
		"sleep 5 && pane=$(tmux list-panes -s -t %s -F '#{pane_id} #{@party_role}' "+
			"| awk '$2==\"claude\"{print $1; exit}') "+
			"&& [ -n \"$pane\" ] "+
			"&& tmux send-keys -t \"$pane\" -l -- '/rename '%s "+
			"&& sleep 0.1 "+
			"&& tmux send-keys -t \"$pane\" Enter",
		config.ShellQuote(session), config.ShellQuote(title),
	)
	return s.Client.RunShell(ctx, session, cmd)
}
