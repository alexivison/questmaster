package session

import (
	"context"
	"fmt"
	"os"

	"github.com/anthropics/ai-config/tools/party-cli/internal/state"
)

// ContinueResult holds the outcome of a Continue operation.
type ContinueResult struct {
	SessionID string
	Reattach  bool // true if session was already running
	Master    bool
}

// Continue resumes a stopped session or reattaches to a running one.
func (s *Service) Continue(ctx context.Context, sessionID string) (ContinueResult, error) {
	// Fast path: session still running — just reattach
	alive, err := s.Client.HasSession(ctx, sessionID)
	if err != nil {
		return ContinueResult{}, fmt.Errorf("check session: %w", err)
	}
	if alive {
		if _, err := ensureRuntimeDir(sessionID); err != nil {
			return ContinueResult{}, err
		}
		return ContinueResult{SessionID: sessionID, Reattach: true}, nil
	}

	// Slow path: reconstruct session from manifest
	m, err := s.Store.Read(sessionID)
	if err != nil {
		return ContinueResult{}, fmt.Errorf("read manifest for %s: %w", sessionID, err)
	}

	cwd := m.Cwd
	if cwd == "" {
		cwd, _ = os.Getwd()
	}
	if _, err := os.Stat(cwd); err != nil {
		cwd, _ = os.Getwd()
	}

	winName := m.WindowName
	if winName == "" {
		winName = windowName(m.Title)
	}

	claudeBin := fallback(m.ClaudeBin, resolveBinary("CLAUDE_BIN", "claude", os.Getenv("HOME")+"/.local/bin/claude"))
	codexBin := fallback(m.CodexBin, resolveBinary("CODEX_BIN", "codex", "/opt/homebrew/bin/codex"))
	agentPath := fallback(m.AgentPath, fmt.Sprintf("%s/.local/bin:/opt/homebrew/bin:%s", os.Getenv("HOME"), os.Getenv("PATH")))
	claudeResumeID := getExtraField(&m, "claude_session_id")
	codexResumeID := getExtraField(&m, "codex_thread_id")

	rtDir, err := ensureRuntimeDir(sessionID)
	if err != nil {
		return ContinueResult{}, err
	}

	if err := s.Client.NewSession(ctx, sessionID, winName, cwd); err != nil {
		return ContinueResult{}, fmt.Errorf("create tmux session: %w", err)
	}

	if err := s.clearClaudeCodeEnv(ctx, sessionID); err != nil {
		return ContinueResult{}, err
	}

	isMaster := m.SessionType == "master"

	if isMaster {
		claudeCmd := buildClaudeCmd(claudeBin, agentPath, claudeResumeID, "", m.Title)
		if err := s.persistResumeIDs(sessionID, rtDir, claudeResumeID, ""); err != nil {
			return ContinueResult{}, err
		}
		if err := s.setResumeEnv(ctx, sessionID, claudeResumeID, ""); err != nil {
			return ContinueResult{}, err
		}
		if err := s.launchMaster(ctx, sessionID, cwd, claudeCmd); err != nil {
			return ContinueResult{}, err
		}
	} else {
		claudeCmd := buildClaudeCmd(claudeBin, agentPath, claudeResumeID, "", m.Title)
		codexCmd := buildCodexCmd(codexBin, agentPath, codexResumeID)
		if err := s.persistResumeIDs(sessionID, rtDir, claudeResumeID, codexResumeID); err != nil {
			return ContinueResult{}, err
		}
		if err := s.setResumeEnv(ctx, sessionID, claudeResumeID, codexResumeID); err != nil {
			return ContinueResult{}, err
		}

		layout := resolveLayout()
		if err := s.Client.SetEnvironment(ctx, sessionID, "PARTY_LAYOUT", string(layout)); err != nil {
			return ContinueResult{}, err
		}

		if layout == LayoutSidebar {
			if err := s.launchSidebar(ctx, sessionID, cwd, codexCmd, claudeCmd, m.Title); err != nil {
				return ContinueResult{}, err
			}
		} else {
			if err := s.launchClassic(ctx, sessionID, cwd, codexCmd, claudeCmd); err != nil {
				return ContinueResult{}, err
			}
		}
	}

	if err := s.setCleanupHook(ctx, sessionID); err != nil {
		return ContinueResult{}, err
	}

	// Update manifest timestamps
	if err := s.Store.Update(sessionID, func(m2 *state.Manifest) {
		setExtraField(m2, "last_resumed_at", nowUTC())
	}); err != nil {
		return ContinueResult{}, fmt.Errorf("update manifest: %w", err)
	}

	// Re-register with parent master if this is a child worker
	parentSession := getExtraField(&m, "parent_session")
	if parentSession != "" {
		_ = s.Store.AddWorker(parentSession, sessionID)
	}

	return ContinueResult{SessionID: sessionID, Master: isMaster}, nil
}

func fallback(v, def string) string {
	if v != "" {
		return v
	}
	return def
}
