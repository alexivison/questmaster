package cmd

import (
	"fmt"
	"strings"

	"github.com/anthropics/ai-party/tools/party-cli/internal/agent"
	"github.com/spf13/cobra"
)

type sessionAgentFlags struct {
	Primary      string
	Companion    string
	NoCompanion  bool
	ResumeAgents []string
	ResumeClaude string
	ResumeCodex  string
}

func (f *sessionAgentFlags) AddFlags(cmd *cobra.Command) {
	cmd.Flags().StringVar(&f.Primary, "primary", "", "agent to use as primary (e.g. codex, claude)")
	cmd.Flags().StringVar(&f.Companion, "companion", "", "agent to use as companion (e.g. claude, codex)")
	cmd.Flags().BoolVar(&f.NoCompanion, "no-companion", false, "run without a companion agent")
	cmd.Flags().StringArrayVar(&f.ResumeAgents, "resume-agent", nil, "resume agent: ROLE=ID (e.g. primary=abc123)")
	cmd.Flags().StringVar(&f.ResumeClaude, "resume-claude", "", "Claude session ID to resume (deprecated: use --resume-agent ROLE=ID)")
	cmd.Flags().StringVar(&f.ResumeCodex, "resume-codex", "", "Codex thread ID to resume (deprecated: use --resume-agent ROLE=ID)")
	_ = cmd.Flags().MarkHidden("resume-claude")
	_ = cmd.Flags().MarkHidden("resume-codex")
}

func (f sessionAgentFlags) ConfigOverrides() *agent.ConfigOverrides {
	if f.Primary == "" && f.Companion == "" && !f.NoCompanion {
		return nil
	}
	return &agent.ConfigOverrides{
		Primary:     f.Primary,
		Companion:   f.Companion,
		NoCompanion: f.NoCompanion,
	}
}

func (f sessionAgentFlags) ResolveResumeIDs(registry *agent.Registry) (string, string, error) {
	resumeByAgent := map[string]string{}
	if f.ResumeClaude != "" {
		resumeByAgent["claude"] = f.ResumeClaude
	}
	if f.ResumeCodex != "" {
		resumeByAgent["codex"] = f.ResumeCodex
	}

	roleResume, err := parseResumeFlags(f.ResumeAgents)
	if err != nil {
		return "", "", err
	}
	for _, binding := range registry.Bindings() {
		if resumeID := roleResume[binding.Role]; resumeID != "" {
			resumeByAgent[binding.Agent.Name()] = resumeID
		}
	}

	return resumeByAgent["claude"], resumeByAgent["codex"], nil
}

func parseResumeFlags(values []string) (map[agent.Role]string, error) {
	resume := make(map[agent.Role]string, len(values))
	for _, value := range values {
		roleName, id, ok := strings.Cut(value, "=")
		if !ok {
			return nil, fmt.Errorf("invalid --resume-agent value %q: want ROLE=ID", value)
		}
		role := agent.Role(strings.TrimSpace(roleName))
		id = strings.TrimSpace(id)
		if id == "" {
			return nil, fmt.Errorf("invalid --resume-agent value %q: missing resume ID", value)
		}
		switch role {
		case agent.RolePrimary, agent.RoleCompanion:
			resume[role] = id
		default:
			return nil, fmt.Errorf("invalid --resume-agent role %q: want primary or companion", roleName)
		}
	}
	return resume, nil
}
