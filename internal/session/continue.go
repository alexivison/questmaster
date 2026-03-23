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
	claudeResumeID := m.ExtraString("claude_session_id")
	codexResumeID := m.ExtraString("codex_thread_id")

	rtDir, err := ensureRuntimeDir(sessionID)
	if err != nil {
		return ContinueResult{}, err
	}

	if err := s.Client.NewSession(ctx, sessionID, winName, cwd); err != nil {
		return ContinueResult{}, fmt.Errorf("create tmux session: %w", err)
	}

	isMaster := m.SessionType == "master"

	if err := s.launchSession(ctx, launchConfig{
		sessionID:      sessionID,
		cwd:            cwd,
		runtimeDir:     rtDir,
		title:          m.Title,
		claudeBin:      claudeBin,
		codexBin:       codexBin,
		agentPath:      agentPath,
		claudeResumeID: claudeResumeID,
		codexResumeID:  codexResumeID,
		master:         isMaster,
	}); err != nil {
		return ContinueResult{}, err
	}

	// Update manifest timestamps
	if err := s.Store.Update(sessionID, func(m2 *state.Manifest) {
		m2.SetExtra("last_resumed_at", state.NowUTC())
	}); err != nil {
		return ContinueResult{}, fmt.Errorf("update manifest: %w", err)
	}

	// Re-register with parent master if this is a child worker
	parentSession := m.ExtraString("parent_session")
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
