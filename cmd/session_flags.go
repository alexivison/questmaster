package cmd

import (
	"fmt"
	"strings"

	"github.com/alexivison/questmaster/internal/agent"
	"github.com/spf13/cobra"
)

type sessionAgentFlags struct {
	Agent       string
	ResumeAgent string
}

func (f *sessionAgentFlags) AddFlags(cmd *cobra.Command) {
	cmd.Flags().StringVar(&f.Agent, "agent", "", "agent to use for this session (e.g. codex, claude)")
	cmd.Flags().StringVar(&f.ResumeAgent, "resume-agent", "", "resume the session agent from this ID")
}

func validateShellSessionFlags(cmd *cobra.Command, enabled bool) error {
	if !enabled {
		return nil
	}
	for _, name := range []string{"master-id", "prompt", "prompt-file", "agent", "resume-agent", "model", "reasoning-effort", "class"} {
		if cmd.Flags().Changed(name) {
			return fmt.Errorf("start --shell: shell sessions cannot take a master/worker role, prompt, agent flag, or class")
		}
	}
	return nil
}

func (f sessionAgentFlags) ConfigOverrides() *agent.ConfigOverrides {
	if f.Agent == "" {
		return nil
	}
	return &agent.ConfigOverrides{
		Agent: f.Agent,
	}
}

func (f sessionAgentFlags) ResolveResumeIDs(registry *agent.Registry, supplied bool) (map[string]string, error) {
	if !supplied {
		return nil, nil
	}
	resumeID := strings.TrimSpace(f.ResumeAgent)
	if resumeID == "" {
		return nil, fmt.Errorf("invalid --resume-agent value: missing resume ID")
	}
	if strings.Contains(resumeID, "=") {
		return nil, fmt.Errorf("invalid --resume-agent value %q: pass an ID without a role", f.ResumeAgent)
	}
	binding, err := registry.ForRole(agent.RoleAgent)
	if err != nil {
		return nil, err
	}
	return map[string]string{binding.Agent.Name(): resumeID}, nil
}
