package session

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/alexivison/questmaster/internal/agent"
	"github.com/alexivison/questmaster/internal/config"
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
	// Respawned is true when a running session's agent had exited and
	// Continue started it again in its pane, resuming its conversation.
	Respawned bool `json:"respawned,omitempty"`
	// AgentExit is how that agent ended: "exit 17" or "signal 9".
	AgentExit string `json:"agent_exit,omitempty"`
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
// below cannot go stale before new-session or a respawn runs.
func (s *Service) continueLocked(ctx context.Context, sessionID string) (ContinueResult, error) {
	m, manifestErr := s.Store.Read(sessionID)
	if manifestErr == nil {
		handle, err := s.router().Route(m)
		if err != nil {
			return ContinueResult{}, err
		}
		s = s.onHandle(handle)
	}
	alive, err := s.Client.HasSession(ctx, sessionID)
	if err != nil {
		return ContinueResult{}, fmt.Errorf("check session: %w", err)
	}
	if alive {
		return s.reattach(ctx, sessionID)
	}

	// Slow path: reconstruct session from manifest
	if manifestErr != nil {
		return ContinueResult{}, fmt.Errorf("read manifest for %s: %w", sessionID, manifestErr)
	}
	if _, err := s.persistPiResumeFromActivity(sessionID); err != nil {
		return ContinueResult{}, fmt.Errorf("persist Pi resume ID: %w", err)
	}
	m, err = s.Store.Read(sessionID)
	if err != nil {
		return ContinueResult{}, fmt.Errorf("read updated manifest for %s: %w", sessionID, err)
	}

	cwd, err := savedCwd(m)
	if err != nil {
		return ContinueResult{}, err
	}
	launch, err := s.continueLaunchFor(m)
	if err != nil {
		return ContinueResult{}, err
	}
	previousServer := m.TmuxServer
	creation, err := s.router().Creation()
	if err != nil {
		return ContinueResult{}, err
	}
	if creation.Label() != "default" && !launch.shell {
		if _, ok := launch.agentResume[agent.RoleAgent]; !ok {
			return ContinueResult{}, fmt.Errorf("session %s has no saved agent resume ID; Continue cannot start a new conversation", sessionID)
		}
	}
	s = s.onHandle(creation)

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
	if err := prepareRuntimeDir(rtDir, sessionID, launch.agents); err != nil {
		return ContinueResult{}, err
	}
	if m.RuntimeDir != rtDir {
		if err := s.Store.Update(sessionID, func(m2 *state.Manifest) { m2.RuntimeDir = rtDir }); err != nil {
			return ContinueResult{}, fmt.Errorf("record runtime dir: %w", err)
		}
	}

	if err := s.prepareCreation(ctx, creation); err != nil {
		return ContinueResult{}, err
	}
	pane, err := s.Client.NewSession(ctx, sessionID, "", cwd)
	if err != nil {
		return ContinueResult{}, fmt.Errorf("create tmux session: %w", err)
	}
	if err := s.Store.Update(sessionID, func(m2 *state.Manifest) { m2.TmuxServer = state.TmuxServer(creation.Label()) }); err != nil {
		return ContinueResult{}, s.continueRollback(ctx, sessionID, previousServer, creation.Label(), false, err)
	}
	if err := s.verifyCreationOwnership(ctx, creation); err != nil {
		return ContinueResult{}, s.continueRollback(ctx, sessionID, previousServer, creation.Label(), true, err)
	}

	isMaster := roleForManifest(m) == roleMaster

	if err := s.launchSession(ctx, launchConfig{
		serverLabel: creation.Label(),
		sessionID:   sessionID,
		pane:        pane,
		cwd:         cwd,
		runtimeDir:  rtDir,
		agentPath:   launch.agentPath,
		master:      isMaster,
		worker:      m.ExtraString("parent_session") != "",
		shell:       launch.shell,
		agentCmds:   launch.agentCmds,
		agents:      launch.agents,
		agentResume: launch.agentResume,
	}); err != nil {
		return ContinueResult{}, s.continueRollback(ctx, sessionID, previousServer, creation.Label(), true, err)
	}

	if err := s.recordResume(sessionID, launch, ""); err != nil {
		return ContinueResult{}, s.continueRollback(ctx, sessionID, previousServer, creation.Label(), true, err)
	}

	// Re-register with parent master if this is a child worker
	parentSession := m.ExtraString("parent_session")
	if parentSession != "" {
		_ = s.Store.AddWorker(parentSession, sessionID)
	}

	return ContinueResult{SessionID: sessionID, Master: isMaster}, nil
}

// reattach continues a running session. It stays manifest-tolerant: a session
// with no readable manifest is reattached as it is. An agent whose process has
// exited, leaving its pane dead (remain-on-exit), is started again in that
// pane.
func (s *Service) reattach(ctx context.Context, sessionID string) (ContinueResult, error) {
	// Pi resume capture is best-effort.
	_, _ = s.persistPiResumeFromActivity(sessionID)
	m, readErr := s.Store.Read(sessionID)
	if readErr == nil {
		if err := s.reuseRuntimeDir(ctx, m); err != nil {
			return ContinueResult{}, err
		}
	}
	if err := s.refreshContinueSessionEnvironment(ctx, sessionID); err != nil {
		return ContinueResult{}, err
	}
	result := ContinueResult{SessionID: sessionID, Reattach: true}
	if readErr != nil {
		return result, nil
	}
	result.Master = roleForManifest(m) == roleMaster
	if len(m.Agents) == 0 {
		return result, nil
	}
	pane, err := s.Client.RolePane(ctx, sessionID, tmux.RoleAgent)
	if errors.Is(err, tmux.ErrRoleNotFound) || errors.Is(err, tmux.ErrRoleAmbiguous) {
		return result, nil
	}
	if err != nil {
		return ContinueResult{}, err
	}
	if !pane.Dead {
		return result, nil
	}
	if m.TmuxServer == "" || m.TmuxServer == "default" {
		creation, err := s.router().Creation()
		if err != nil {
			return ContinueResult{}, err
		}
		if creation.Label() != "default" {
			allDead, err := s.Client.AllPanesDead(ctx, sessionID)
			if err != nil {
				return ContinueResult{}, err
			}
			if allDead {
				if err := s.retireDeadLegacy(ctx, m); err != nil {
					return ContinueResult{}, err
				}
				return s.continueLocked(ctx, sessionID)
			}
		}
	}
	if err := s.respawnDeadAgent(ctx, m, pane); err != nil {
		return ContinueResult{}, err
	}
	result.Respawned, result.AgentExit = true, pane.Exit
	return result, nil
}

func (s *Service) retireDeadLegacy(ctx context.Context, m state.Manifest) error {
	// Validate the conversation before killing its old container.
	launch, err := s.continueLaunchFor(m)
	if err != nil {
		return err
	}
	if _, ok := launch.agentResume[agent.RoleAgent]; !ok {
		return fmt.Errorf("session %s has no saved agent resume ID; Continue cannot retire it; run qm delete %s and start a new session", m.SessionID, m.SessionID)
	}
	if _, err := savedCwd(m); err != nil {
		return err
	}
	dir, err := m.RuntimeDirOrLegacy()
	if err != nil {
		return err
	}
	script := filepath.Join(dir, "cleanup.sh")
	renamed := false
	if err := os.Rename(script, script+".retired"); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("retire legacy cleanup: %w", err)
	} else if err == nil {
		renamed = true
	}
	if err := s.Client.KillSession(ctx, m.SessionID); err != nil {
		if renamed {
			_ = os.Rename(script+".retired", script)
		}
		return err
	}
	return nil
}

// respawnDeadAgent starts a running session's exited agent again in its pane,
// resuming its conversation by the saved resume ID, and records how the agent
// ended. Without a saved ID the harness would start a new conversation in
// place of the one that ended, so it refuses and names the recovery.
func (s *Service) respawnDeadAgent(ctx context.Context, m state.Manifest, pane tmux.PaneStatus) error {
	launch, err := s.continueLaunchFor(m)
	if err != nil {
		return err
	}
	if _, ok := launch.agentResume[agent.RoleAgent]; !ok {
		name := agent.SpecOf(launch.agents[agent.RoleAgent].Name()).DisplayName
		return fmt.Errorf("the agent in session %s exited (%s) and there is no saved %s resume ID, so Continue cannot resume its conversation; delete the session (questmaster delete %s) and start a new one", m.SessionID, pane.Exit, name, m.SessionID)
	}
	cwd, err := savedCwd(m)
	if err != nil {
		return err
	}
	// A legacy session's directory may be gone and is never recreated; the
	// manifest and the session environment carry the resume ID either way.
	if m.RuntimeDir != "" {
		if err := s.persistResumeIDs(m.RuntimeDir, launch.agentResume); err != nil {
			return err
		}
	}
	if err := s.setResumeEnv(ctx, m.SessionID, launch.agentResume); err != nil {
		return err
	}
	if err := s.Client.RespawnPane(ctx, pane.ID, cwd, launch.agentCmds[agent.RoleAgent]); err != nil {
		return fmt.Errorf("respawn agent in %s: %w", m.SessionID, err)
	}
	return s.recordResume(m.SessionID, launch, pane.Exit)
}

// savedCwd returns the directory a session is relaunched in. It is never
// swapped for another: a session whose directory is gone stays stopped until
// the directory is back or the session is deleted.
func savedCwd(m state.Manifest) (string, error) {
	if m.Cwd == "" {
		return "", fmt.Errorf("session %s has no saved working directory; delete it (questmaster delete %s) and start a new session", m.SessionID, m.SessionID)
	}
	if info, err := os.Stat(m.Cwd); err != nil || !info.IsDir() {
		return "", fmt.Errorf("session %s's working directory %s is gone; recreate it (mkdir -p %s) or delete the session (questmaster delete %s)", m.SessionID, m.Cwd, config.ShellQuote(m.Cwd), m.SessionID)
	}
	return m.Cwd, nil
}

// continueLaunch is what Continue relaunches for a session's manifest.
type continueLaunch struct {
	shell          bool
	agentPath      string
	agentCmds      map[agent.Role]string
	agents         map[agent.Role]agent.Agent
	agentResume    map[agent.Role]resumeInfo
	manifestAgents []state.AgentManifest
}

// continueLaunchFor builds the agent commands that resume a session's
// conversation from its manifest.
func (s *Service) continueLaunchFor(m state.Manifest) (continueLaunch, error) {
	l := continueLaunch{
		shell:       len(m.Agents) == 0,
		agentPath:   mergePathLists(os.Getenv("QUESTMASTER_PATH_PREFIX"), m.AgentPath, defaultAgentPath()),
		agentCmds:   map[agent.Role]string{},
		agents:      map[agent.Role]agent.Agent{},
		agentResume: map[agent.Role]resumeInfo{},
	}
	if l.shell {
		return l, nil
	}
	agentRole := agentSessionRole(roleForManifest(m))
	manifestSpecs, err := orderedManifestAgents(m)
	if err != nil {
		return continueLaunch{}, err
	}
	l.manifestAgents = make([]state.AgentManifest, 0, len(manifestSpecs))

	for _, agentState := range manifestSpecs {
		role := agent.Role(agentState.Role)
		provider, err := agent.Resolve(agentState.Name, s.Registry)
		if err != nil {
			return continueLaunch{}, fmt.Errorf("resolve provider %q: %w", agentState.Name, err)
		}

		cli, resolvedPath, resolved := resolveAgentBinaryForLaunch(provider, agentState.CLI, l.agentPath)
		if !resolved {
			return continueLaunch{}, agentBinaryNotFoundError(provider)
		}
		l.agentPath = resolvedPath

		resumeID := agentState.ResumeID
		if resumeID == "" {
			resumeID = m.ExtraString(provider.ResumeKey())
		}

		l.agents[role] = provider
		brief := ""
		if role == agent.RoleAgent && agentRole == agent.RoleWorker {
			brief = workerParentBrief(m.ExtraString("parent_session"), "")
		}
		l.agentCmds[role] = provider.BuildCmd(agent.CmdOpts{
			Binary:          cli,
			AgentPath:       l.agentPath,
			ResumeID:        resumeID,
			Title:           m.Title,
			Role:            agentRole,
			SystemBrief:     brief,
			Continuing:      true,
			Model:           agentState.Model,
			ReasoningEffort: agentState.ReasoningEffort,
		})
		if resumeID != "" {
			l.agentResume[role] = resumeInfo{
				provider: provider,
				resumeID: resumeID,
			}
		}

		l.manifestAgents = append(l.manifestAgents, state.AgentManifest{
			Name:     provider.Name(),
			Role:     string(role),
			CLI:      cli,
			ResumeID: resumeID,
			Window:   tmux.WindowWorkspace,
			// A resumed session keeps the harness's own conversation
			// model, but the model it was first launched with stays
			// recorded so it survives in the recents list.
			Model:           agentState.Model,
			ReasoningEffort: agentState.ReasoningEffort,
		})
	}
	return l, nil
}

// recordResume stores what a relaunch used (the agents, their path and resume
// IDs) and when, and how the agent it replaced ended when there was one.
func (s *Service) recordResume(sessionID string, l continueLaunch, agentExit string) error {
	if err := s.Store.Update(sessionID, func(m2 *state.Manifest) {
		if !l.shell {
			m2.Agents = l.manifestAgents
		}
		m2.AgentPath = l.agentPath
		for _, info := range l.agentResume {
			if info.provider != nil {
				m2.SetExtra(info.provider.ResumeKey(), info.resumeID)
			}
		}
		m2.SetExtra("last_resumed_at", state.NowUTC())
		if agentExit != "" {
			m2.SetExtra("last_agent_exit", agentExit)
		}
	}); err != nil {
		return fmt.Errorf("update manifest: %w", err)
	}
	return nil
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
	label := "default"
	if m, err := s.Store.Read(sessionID); err == nil && m.TmuxServer != "" {
		label = string(m.TmuxServer)
	}
	if err := s.Client.SetEnvironment(ctx, sessionID, "QUESTMASTER_TMUX_SERVER", label); err != nil {
		return err
	}
	if err := s.setPaneCreationLabel(ctx, sessionID, label); err != nil {
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

// continueRollback preserves the manifest and runtime for a later retry.
// The prior route is restored only after the new container is gone.
func (s *Service) continueRollback(ctx context.Context, sessionID string, previousServer state.TmuxServer, newServer string, routeRecorded bool, cause error) error {
	ctx, cancel := rollbackContext(ctx)
	defer cancel()
	if err := s.Client.KillSession(ctx, sessionID); err != nil {
		if !routeRecorded {
			if recordErr := s.Store.Update(sessionID, func(m *state.Manifest) { m.TmuxServer = state.TmuxServer(newServer) }); recordErr != nil {
				return errors.Join(cause, fmt.Errorf("rollback kill failed: %w", err), fmt.Errorf("record live tmux server: %w", recordErr))
			}
		}
		return errors.Join(cause, fmt.Errorf("rollback kill failed: %w", err))
	}
	if routeRecorded {
		if err := s.Store.Update(sessionID, func(m *state.Manifest) { m.TmuxServer = previousServer }); err != nil {
			return errors.Join(cause, fmt.Errorf("restore previous tmux server: %w", err))
		}
	}
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
		m, readErr := s.Store.Read(wid)
		if readErr != nil {
			if errors.Is(readErr, os.ErrNotExist) {
				continue
			}
			failed = append(failed, wid)
			continue
		}
		handle, err := s.router().Route(m)
		if err != nil {
			failed = append(failed, wid)
			continue
		}
		alive, err := handle.Client().HasSession(ctx, wid)
		if err == nil && alive {
			continue // already running
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
