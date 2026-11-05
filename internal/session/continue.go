package session

import (
	"context"
	"errors"
	"fmt"
	"os"

	"github.com/alexivison/questmaster/internal/agent"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
)

// ContinueResult holds the outcome of a Continue operation.
type ContinueResult struct {
	SessionID      string   `json:"session_id"`
	Reattach       bool     `json:"reattach"` // true if session was already running
	Master         bool     `json:"master"`
	RevivedWorkers []string `json:"revived_workers,omitempty"` // worker IDs auto-continued on master cascade
	FailedWorkers  []string `json:"failed_workers,omitempty"`  // worker IDs that failed to auto-continue
}

// Continue resumes a stopped session or reattaches to a running one. It holds
// the session's lifecycle lock, and a worker's Continue its master's first. A
// master's workers are continued after its own lock is released.
func (s *Service) Continue(ctx context.Context, sessionID string) (ContinueResult, error) {
	parent := ""
	if m, err := s.Store.Read(sessionID); err == nil {
		if p := m.ExtraString("parent_session"); p != sessionID && state.IsValidSessionID(p) {
			parent = p
		}
	}
	var result ContinueResult
	err := s.locked(ctx, []string{parent, sessionID}, func(ctx context.Context) error {
		var err error
		result, err = s.continueLocked(ctx, sessionID)
		return err
	})
	if err != nil {
		return ContinueResult{}, err
	}
	// Cascade even on reattach: a master may be alive while its workers are dead.
	if result.Master {
		result.RevivedWorkers, result.FailedWorkers = s.cascadeWorkers(ctx, sessionID)
	}
	return result, nil
}

// continueLocked runs under Continue's lifecycle locks, so the liveness check
// below cannot go stale before new-session runs.
func (s *Service) continueLocked(ctx context.Context, sessionID string) (ContinueResult, error) {
	// Fast path: session still running — just reattach
	alive, err := s.Client.HasSession(ctx, sessionID)
	if err != nil {
		return ContinueResult{}, fmt.Errorf("check session: %w", err)
	}
	if alive {
		// Reattach must stay manifest-tolerant; Pi resume capture is best-effort.
		_, _ = s.persistPiResumeFromActivity(sessionID)
		m, err := s.Store.Read(sessionID)
		if err == nil {
			if err := s.reuseRuntimeDir(ctx, m); err != nil {
				return ContinueResult{}, err
			}
		}
		if err := s.refreshContinueSessionEnvironment(ctx, sessionID); err != nil {
			return ContinueResult{}, err
		}
		master := err == nil && roleForManifest(m) == roleMaster
		return ContinueResult{SessionID: sessionID, Reattach: true, Master: master}, nil
	}

	// Slow path: reconstruct session from manifest
	m, err := s.Store.Read(sessionID)
	if err != nil {
		return ContinueResult{}, fmt.Errorf("read manifest for %s: %w", sessionID, err)
	}
	if _, err := s.persistPiResumeFromActivity(sessionID); err != nil {
		return ContinueResult{}, fmt.Errorf("persist Pi resume ID: %w", err)
	}
	m, err = s.Store.Read(sessionID)
	if err != nil {
		return ContinueResult{}, fmt.Errorf("read updated manifest for %s: %w", sessionID, err)
	}

	cwd := m.Cwd
	if cwd == "" {
		cwd, _ = os.Getwd()
	}
	if _, err := os.Stat(cwd); err != nil {
		cwd, _ = os.Getwd()
	}

	role := roleForManifest(m)
	agentRole := agentSessionRole(role)

	shell := len(m.Agents) == 0
	agentPath := mergePathLists(os.Getenv("QUESTMASTER_PATH_PREFIX"), m.AgentPath, defaultAgentPath())
	agentCmds := map[agent.Role]string{}
	launchAgents := map[agent.Role]agent.Agent{}
	agentResume := map[agent.Role]resumeInfo{}
	var manifestAgents []state.AgentManifest

	if !shell {
		manifestSpecs, err := orderedManifestAgents(m)
		if err != nil {
			return ContinueResult{}, err
		}

		agentCmds = make(map[agent.Role]string, len(manifestSpecs))
		launchAgents = make(map[agent.Role]agent.Agent, len(manifestSpecs))
		agentResume = make(map[agent.Role]resumeInfo, len(manifestSpecs))
		manifestAgents = make([]state.AgentManifest, 0, len(manifestSpecs))

		for _, agentState := range manifestSpecs {
			role := agent.Role(agentState.Role)
			provider, err := agent.Resolve(agentState.Name, s.Registry)
			if err != nil {
				return ContinueResult{}, fmt.Errorf("resolve provider %q: %w", agentState.Name, err)
			}

			cli, resolvedPath, resolved := resolveAgentBinaryForLaunch(provider, agentState.CLI, agentPath)
			if !resolved {
				return ContinueResult{}, agentBinaryNotFoundError(provider)
			}
			agentPath = resolvedPath

			resumeID := agentState.ResumeID
			if resumeID == "" {
				resumeID = m.ExtraString(provider.ResumeKey())
			}

			launchAgents[role] = provider
			brief := ""
			if role == agent.RoleAgent && agentRole == agent.RoleWorker {
				brief = workerParentBrief(m.ExtraString("parent_session"), "")
			}
			agentCmds[role] = provider.BuildCmd(agent.CmdOpts{
				Binary:          cli,
				AgentPath:       agentPath,
				ResumeID:        resumeID,
				Title:           m.Title,
				Role:            agentRole,
				SystemBrief:     brief,
				Continuing:      true,
				Model:           agentState.Model,
				ReasoningEffort: agentState.ReasoningEffort,
			})
			if resumeID != "" {
				agentResume[role] = resumeInfo{
					provider: provider,
					resumeID: resumeID,
				}
			}

			manifestAgents = append(manifestAgents, state.AgentManifest{
				Name:     provider.Name(),
				Role:     string(role),
				CLI:      cli,
				ResumeID: resumeID,
				Window:   agentState.Window,
				// A resumed session keeps the harness's own conversation
				// model, but the model it was first launched with stays
				// recorded so it survives in the recents list.
				Model:           agentState.Model,
				ReasoningEffort: agentState.ReasoningEffort,
			})
		}

		for i := range manifestAgents {
			manifestAgents[i].Window = tmux.WindowWorkspace
		}
	}

	rtDir, err := m.RuntimeDirOrLegacy()
	if err != nil {
		return ContinueResult{}, err
	}
	if m.RuntimeDir == "" {
		// A legacy directory belonged to the tmux session that is gone;
		// the relaunched session gets a private one, recorded before launch so
		// every reader finds it.
		rtDir = state.NewRuntimeDir(s.Store.Root(), sessionID)
	}
	if err := prepareRuntimeDir(rtDir, sessionID, launchAgents); err != nil {
		return ContinueResult{}, err
	}
	if m.RuntimeDir != rtDir {
		if err := s.Store.Update(sessionID, func(m2 *state.Manifest) { m2.RuntimeDir = rtDir }); err != nil {
			return ContinueResult{}, fmt.Errorf("record runtime dir: %w", err)
		}
	}

	if err := s.Client.NewSession(ctx, sessionID, "", cwd); err != nil {
		return ContinueResult{}, s.continueRollback(ctx, sessionID, false, fmt.Errorf("create tmux session: %w", err))
	}

	isMaster := role == roleMaster

	if err := s.launchSession(ctx, launchConfig{
		sessionID:   sessionID,
		cwd:         cwd,
		runtimeDir:  rtDir,
		agentPath:   agentPath,
		master:      isMaster,
		worker:      m.ExtraString("parent_session") != "",
		shell:       shell,
		agentCmds:   agentCmds,
		agents:      launchAgents,
		agentResume: agentResume,
	}); err != nil {
		return ContinueResult{}, s.continueRollback(ctx, sessionID, true, err)
	}

	// Update manifest timestamps
	if err := s.Store.Update(sessionID, func(m2 *state.Manifest) {
		if !shell {
			m2.Agents = manifestAgents
		}
		m2.AgentPath = agentPath
		for _, info := range agentResume {
			if info.provider != nil {
				m2.SetExtra(info.provider.ResumeKey(), info.resumeID)
			}
		}
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

// reuseRuntimeDir hands a live session the runtime directory its manifest
// records, recreating a recorded one that has gone missing. A legacy
// session's directory is used as it is and never recreated.
func (s *Service) reuseRuntimeDir(ctx context.Context, m state.Manifest) error {
	dir, err := m.RuntimeDirOrLegacy()
	if err != nil {
		return err
	}
	if m.RuntimeDir != "" {
		if err := ensureRuntimeDir(dir, m.SessionID); err != nil {
			return err
		}
	}
	return s.Client.SetEnvironment(ctx, m.SessionID, state.RuntimeDirEnv, dir)
}

func (s *Service) refreshContinueSessionEnvironment(ctx context.Context, sessionID string) error {
	if err := s.Client.SetEnvironment(ctx, sessionID, state.SessionEnv, sessionID); err != nil {
		return err
	}
	agentPath := defaultAgentPath()
	if m, err := s.Store.Read(sessionID); err == nil {
		agentPath = mergePathLists(os.Getenv("QUESTMASTER_PATH_PREFIX"), m.AgentPath, agentPath)
	}
	if agentPath != "" {
		if err := s.Client.SetEnvironment(ctx, sessionID, "PATH", agentPath); err != nil {
			return err
		}
	}
	return s.refreshAppOwnedSessionEnvironment(ctx, sessionID)
}

// continueRollback best-effort kills a partially launched tmux session after a
// Continue failure, but only one this call created: a failed new-session can
// mean another caller owns a session by that name. Unlike Start's rollback
// (startRollbackError), it MUST preserve the manifest and runtime/state dirs:
// Continue reconstructs from a pre-existing manifest, so a later retry depends
// on that manifest surviving.
func (s *Service) continueRollback(ctx context.Context, sessionID string, created bool, cause error) error {
	if !created {
		return cause
	}
	ctx, cancel := rollbackContext(ctx)
	defer cancel()
	_ = s.Client.KillSession(ctx, sessionID)
	return cause
}

// cascadeWorkers continues all orphaned workers for a master session.
// A worker is orphaned if it has a manifest on disk but no live tmux session.
// Workers whose manifests were deleted (intentionally stopped) are skipped.
// It runs without the master's lifecycle lock: each Continue takes it.
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

func orderedManifestAgents(m state.Manifest) ([]state.AgentManifest, error) {
	indexed := make(map[agent.Role]state.AgentManifest, len(m.Agents))
	for _, spec := range m.Agents {
		role := agent.Role(spec.Role)
		switch role {
		case agent.RoleAgent:
			indexed[role] = spec
		default:
			continue
		}
	}

	if _, ok := indexed[agent.RoleAgent]; !ok {
		return nil, fmt.Errorf("manifest is missing an agent")
	}

	ordered := []state.AgentManifest{indexed[agent.RoleAgent]}
	return ordered, nil
}
