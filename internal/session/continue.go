package session

import (
	"context"
	"errors"
	"fmt"
	"os"

	"github.com/anthropics/ai-party/tools/party-cli/internal/agent"
	"github.com/anthropics/ai-party/tools/party-cli/internal/state"
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

	manifestSpecs, err := orderedManifestAgents(m)
	if err != nil {
		return ContinueResult{}, err
	}

	agentPath := fallback(m.AgentPath, defaultAgentPath())
	agentCmds := make(map[agent.Role]string, len(manifestSpecs))
	launchAgents := make(map[agent.Role]agent.Agent, len(manifestSpecs))
	agentResume := make(map[agent.Role]resumeInfo, len(manifestSpecs))
	manifestAgents := make([]state.AgentManifest, 0, len(manifestSpecs))

	for _, agentState := range manifestSpecs {
		role := agent.Role(agentState.Role)
		provider, err := agent.Resolve(agentState.Name, s.Registry)
		if err != nil {
			return ContinueResult{}, fmt.Errorf("resolve provider %q: %w", agentState.Name, err)
		}

		cli := agentState.CLI
		if cli == "" {
			var resolved bool
			cli, resolved = resolveAgentBinary(provider)
			if !resolved {
				if role == agent.RoleCompanion {
					fmt.Fprintf(os.Stderr, "party-cli: warning: skipping %s companion; binary not found (%s)\n", provider.Name(), cli)
					continue
				}
				return ContinueResult{}, fmt.Errorf("resolve %s binary: not found", provider.Name())
			}
		}

		resumeID := agentState.ResumeID
		if resumeID == "" {
			resumeID = m.ExtraString(provider.ResumeKey())
		}

		launchAgents[role] = provider
		agentCmds[role] = provider.BuildCmd(agent.CmdOpts{
			Binary:    cli,
			AgentPath: agentPath,
			ResumeID:  resumeID,
			Title:     m.Title,
			Master:    m.SessionType == "master" && role == agent.RolePrimary,
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
		})
	}

	layout := resolveLayout()
	hasCompanion := agentCmds[agent.RoleCompanion] != ""
	for i := range manifestAgents {
		manifestAgents[i].Window = agentWindow(layout, m.SessionType == "master", agent.Role(manifestAgents[i].Role), hasCompanion)
	}

	rtDir, err := ensureRuntimeDir(sessionID)
	if err != nil {
		return ContinueResult{}, err
	}

	if err := s.Client.NewSession(ctx, sessionID, winName, cwd); err != nil {
		return ContinueResult{}, fmt.Errorf("create tmux session: %w", err)
	}

	isMaster := m.SessionType == "master"

	if err := s.launchSession(ctx, launchConfig{
		sessionID:   sessionID,
		cwd:         cwd,
		runtimeDir:  rtDir,
		title:       m.Title,
		agentPath:   agentPath,
		master:      isMaster,
		worker:      m.ExtraString("parent_session") != "",
		agentCmds:   agentCmds,
		agents:      launchAgents,
		agentResume: agentResume,
	}); err != nil {
		return ContinueResult{}, err
	}

	// Update manifest timestamps
	if err := s.Store.Update(sessionID, func(m2 *state.Manifest) {
		m2.Agents = manifestAgents
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

func orderedManifestAgents(m state.Manifest) ([]state.AgentManifest, error) {
	indexed := make(map[agent.Role]state.AgentManifest, len(m.Agents))
	for _, spec := range m.Agents {
		role := agent.Role(spec.Role)
		switch role {
		case agent.RolePrimary, agent.RoleCompanion:
			indexed[role] = spec
		default:
			return nil, fmt.Errorf("manifest has unknown agent role %q", spec.Role)
		}
	}

	if _, ok := indexed[agent.RolePrimary]; !ok {
		return nil, fmt.Errorf("manifest is missing a primary agent")
	}

	ordered := []state.AgentManifest{indexed[agent.RolePrimary]}
	if spec, ok := indexed[agent.RoleCompanion]; ok {
		ordered = append(ordered, spec)
	}
	if len(ordered) > 1 && ordered[0].Name == ordered[1].Name && ordered[0].Name != "" {
		return nil, fmt.Errorf("manifest uses the same agent %q for primary and companion, which is not supported", ordered[0].Name)
	}
	return ordered, nil
}
