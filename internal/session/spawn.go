package session

import (
	"context"
	"fmt"

	"github.com/anthropics/ai-party/tools/party-cli/internal/agent"
	"github.com/anthropics/ai-party/tools/party-cli/internal/state"
)

// SpawnOpts configures a worker session spawned from a master.
type SpawnOpts struct {
	Title          string
	Cwd            string
	ClaudeResumeID string
	CodexResumeID  string
	Prompt         string
	Detached       bool
	Registry       *agent.Registry
}

// Spawn creates a new worker session owned by the given master.
func (s *Service) Spawn(ctx context.Context, masterID string, opts SpawnOpts) (StartResult, error) {
	if !state.IsValidPartyID(masterID) {
		return StartResult{}, fmt.Errorf("invalid master session name %q", masterID)
	}

	m, err := s.Store.Read(masterID)
	if err != nil {
		return StartResult{}, fmt.Errorf("read master manifest: %w", err)
	}
	if m.SessionType != "master" {
		return StartResult{}, fmt.Errorf("session %q is not a master", masterID)
	}

	cwd := opts.Cwd
	if cwd == "" {
		cwd = m.Cwd
	}

	registry := opts.Registry
	if registry == nil {
		var err error
		registry, err = WorkerSpawnRegistryWithBase(m, s.Registry, nil)
		if err != nil {
			return StartResult{}, fmt.Errorf("resolve worker agent layout: %w", err)
		}
	}

	child := *s
	child.Registry = registry

	return child.Start(ctx, StartOpts{
		Title:          opts.Title,
		Cwd:            cwd,
		MasterID:       masterID,
		ClaudeResumeID: opts.ClaudeResumeID,
		CodexResumeID:  opts.CodexResumeID,
		Prompt:         opts.Prompt,
		Detached:       opts.Detached,
	})
}

// WorkerSpawnRegistry resolves the default worker agent layout for a master.
// Workers inherit the master's primary agent and, by default, run without a
// companion so orchestration stays single-threaded until explicitly requested.
func WorkerSpawnRegistry(master state.Manifest, overrides *agent.ConfigOverrides) (*agent.Registry, error) {
	return WorkerSpawnRegistryWithBase(master, nil, overrides)
}

func WorkerSpawnRegistryWithBase(master state.Manifest, base *agent.Registry, overrides *agent.ConfigOverrides) (*agent.Registry, error) {
	effective := overrides
	if effective == nil {
		effective = &agent.ConfigOverrides{
			Primary:     masterPrimaryAgent(master),
			NoCompanion: true,
		}
	}
	cfg, err := agent.LoadConfig(effective)
	if err != nil {
		return nil, err
	}
	if base != nil {
		for name := range cfg.Agents {
			if provider, err := base.Get(name); err == nil && provider.Binary() != "" {
				cfg.Agents[name] = agent.AgentConfig{CLI: provider.Binary()}
			}
		}
	}
	return agent.NewRegistry(cfg)
}

func masterPrimaryAgent(master state.Manifest) string {
	for _, spec := range master.Agents {
		if spec.Role == string(agent.RolePrimary) && spec.Name != "" {
			return spec.Name
		}
	}
	if master.ExtraString("claude_session_id") != "" || master.ClaudeBin != "" {
		return "claude"
	}
	if master.ExtraString("codex_thread_id") != "" || master.CodexBin != "" {
		return "codex"
	}
	return "claude"
}
