package agent

import (
	"context"
	"fmt"

	"github.com/anthropics/ai-party/tools/party-cli/internal/config"
	"github.com/anthropics/ai-party/tools/party-cli/internal/tmux"
)

// Pi implements the built-in Pi provider stub.
//
// Phase 1 stub: provider registers and BuildCmd compiles, but FilterPaneLines
// returns the generic agent filter (real implementation lands in Phase 2) and
// no Pi-specific tests exist yet (Phase 4).
type Pi struct {
	cli string
}

// NewPi constructs a Pi provider from config.
func NewPi(cfg AgentConfig) *Pi {
	cli := cfg.CLI
	if cli == "" {
		cli = "pi"
	}
	return &Pi{cli: cli}
}

func (p *Pi) Name() string        { return "pi" }
func (p *Pi) DisplayName() string { return "Pi" }
func (p *Pi) Binary() string      { return p.cli }

func (p *Pi) BuildCmd(opts CmdOpts) string {
	binary := opts.Binary
	if binary == "" {
		binary = p.Binary()
	}

	cmd := fmt.Sprintf("export PATH=%s; exec %s",
		config.ShellQuote(opts.AgentPath), config.ShellQuote(binary))
	systemPrompt := systemPromptForRole(opts.Role, p.MasterPrompt(), p.StandalonePrompt(), p.WorkerPrompt(), opts.SystemBrief)
	if systemPrompt != "" {
		cmd += " --append-system-prompt " + config.ShellQuote(systemPrompt)
	}
	if opts.Role == RoleMaster && opts.SystemBrief != "" {
		cmd += " --append-system-prompt " + config.ShellQuote(opts.SystemBrief)
	}
	if opts.Role == RoleMaster {
		cmd += " --thinking high"
	}
	if opts.ResumeID != "" {
		cmd += " --session " + config.ShellQuote(opts.ResumeID)
	}
	if opts.Prompt != "" {
		cmd += " " + config.ShellQuote(opts.Prompt)
	}
	return cmd
}

func (p *Pi) ResumeKey() string        { return "pi_session_id" }
func (p *Pi) ResumeFileName() string   { return "pi-session-id" }
func (p *Pi) EnvVar() string           { return "PI_SESSION_ID" }
func (p *Pi) MasterPrompt() string     { return claudeMasterPrompt }
func (p *Pi) StandalonePrompt() string { return claudeStandalonePrompt }
func (p *Pi) WorkerPrompt() string     { return claudeWorkerPrompt }

func (p *Pi) FilterPaneLines(raw string, max int) []string {
	return tmux.FilterAgentLines(raw, max)
}

func (p *Pi) PreLaunchSetup(_ context.Context, _ TmuxClient, _ string) error {
	return nil
}

func (p *Pi) BinaryEnvVar() string { return "PI_BIN" }
func (p *Pi) FallbackPath() string { return "/opt/homebrew/bin/pi" }
