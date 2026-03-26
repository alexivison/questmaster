package session

import (
	"context"
	"errors"
	"fmt"
	"os"

	"github.com/anthropics/ai-config/tools/party-cli/internal/state"
)

// ContinueResult holds the outcome of a Continue operation.
type ContinueResult struct {
	SessionID      string
	Reattach       bool // true if session was already running
	Master         bool
	RevivedWorkers []string // worker IDs auto-continued on master cascade
	FailedWorkers  []string // worker IDs that failed to auto-continue
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
		result := ContinueResult{SessionID: sessionID, Reattach: true}
		// Cascade even on reattach — master may be alive but workers dead.
		m, err := s.Store.Read(sessionID)
		if err == nil && m.SessionType == "master" {
			result.Master = true
			result.RevivedWorkers, result.FailedWorkers = s.cascadeWorkers(ctx, sessionID)
		}
		return result, nil
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

	role := roleStandalone
	if m.SessionType == "master" {
		role = roleMaster
	} else if m.ExtraString("parent_session") != "" {
		role = roleWorker
	}
	// Always recompute — legacy manifests may have stale names without role suffixes.
	winName := windowName(m.Title, role)

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
		worker:         m.ExtraString("parent_session") != "",
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

	result := ContinueResult{SessionID: sessionID, Master: isMaster}

	// Cascade: auto-continue orphaned workers (manifest exists, tmux dead).
	if isMaster {
		result.RevivedWorkers, result.FailedWorkers = s.cascadeWorkers(ctx, sessionID)
	}

	return result, nil
}

// cascadeWorkers continues all orphaned workers for a master session.
// A worker is orphaned if it has a manifest on disk but no live tmux session.
// Workers whose manifests were deleted (intentionally stopped) are skipped.
func (s *Service) cascadeWorkers(ctx context.Context, masterID string) (revived, failed []string) {
	workerIDs, err := s.Store.GetWorkers(masterID)
	if err != nil {
		return nil, nil
	}

	for _, wid := range workerIDs {
		alive, err := s.Client.HasSession(ctx, wid)
		if err == nil && alive {
			continue // already running
		}

		if _, err := s.Store.Read(wid); err != nil {
			if errors.Is(err, os.ErrNotExist) {
				continue // no manifest — intentionally stopped, skip
			}
			failed = append(failed, wid) // corrupt/unreadable manifest
			continue
		}

		if _, err := s.Continue(ctx, wid); err != nil {
			failed = append(failed, wid)
		} else {
			revived = append(revived, wid)
		}
	}
	return revived, failed
}

func fallback(v, def string) string {
	if v != "" {
		return v
	}
	return def
}
