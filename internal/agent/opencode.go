package agent

import (
	"context"
	"fmt"

	"github.com/alexivison/questmaster/internal/config"
	"github.com/alexivison/questmaster/internal/tmux"
)

const (
	defaultOpenCodeModel = "opencode/big-pickle"

	// OpenCode role agent names installed by the hooks.OpenCodeInstaller and
	// selected by OpenCode.BuildCmd.
	OpenCodeMasterAgentName     = "questmaster-master"
	OpenCodeStandaloneAgentName = "questmaster-standalone"
	OpenCodeWorkerAgentName     = "questmaster-worker"
)

// OpenCode implements the built-in OpenCode provider.
//
// OpenCode 1.17.11 has proven TUI support for --agent, --prompt, --model, and
// --session. It does not expose a proven role/system prompt CLI flag, so
// Questmaster role prompts are represented by role-specific OpenCode agent
// names installed by hooks.OpenCodeInstaller.
type OpenCode struct {
	cli           string
	model         string
	openCodeAgent string
}

// NewOpenCode constructs an OpenCode provider from config.
func NewOpenCode(cfg AgentConfig) *OpenCode {
	cli := cfg.CLI
	if cli == "" {
		cli = "opencode"
	}
	model := cfg.Model
	if model == "" {
		model = defaultOpenCodeModel
	}
	return &OpenCode{
		cli:           cli,
		model:         model,
		openCodeAgent: cfg.OpenCodeAgent,
	}
}

func (o *OpenCode) Name() string        { return "opencode" }
func (o *OpenCode) DisplayName() string { return "OpenCode" }
func (o *OpenCode) Description() string {
	return "OpenCode TUI harness with plugin-backed state tracking once the OpenCode bridge is installed"
}
func (o *OpenCode) Binary() string { return o.cli }

func (o *OpenCode) BuildCmd(opts CmdOpts) string {
	binary := opts.Binary
	if binary == "" {
		binary = o.Binary()
	}

	cmd := fmt.Sprintf("export PATH=%s; exec %s --model %s --agent %s",
		config.ShellQuote(opts.AgentPath),
		config.ShellQuote(binary),
		config.ShellQuote(o.model),
		config.ShellQuote(o.agentName(opts.Role)))
	if opts.ResumeID != "" {
		cmd += " --session " + config.ShellQuote(opts.ResumeID)
	}
	if opts.Prompt != "" {
		cmd += " --prompt " + config.ShellQuote(opts.Prompt)
	}
	return cmd
}

func (o *OpenCode) agentName(role SessionRole) string {
	if o.openCodeAgent != "" {
		return o.openCodeAgent
	}
	switch role {
	case RoleMaster:
		return OpenCodeMasterAgentName
	case RoleWorker:
		return OpenCodeWorkerAgentName
	case RoleStandalone:
		fallthrough
	default:
		return OpenCodeStandaloneAgentName
	}
}

func (o *OpenCode) ResumeKey() string        { return "opencode_session_id" }
func (o *OpenCode) ResumeFileName() string   { return "opencode-session-id" }
func (o *OpenCode) EnvVar() string           { return "OPENCODE_SESSION_ID" }
func (o *OpenCode) MasterPrompt() string     { return masterPromptWithGuide() }
func (o *OpenCode) StandalonePrompt() string { return standalonePrompt }
func (o *OpenCode) WorkerPrompt() string     { return workerPrompt }

func (o *OpenCode) FilterPaneLines(raw string, max int) []string {
	return tmux.FilterAgentLines(raw, max)
}

func (o *OpenCode) PreLaunchSetup(_ context.Context, _ TmuxClient, _ string) error {
	return nil
}

func (o *OpenCode) BinaryEnvVar() string { return "OPENCODE_BIN" }
func (o *OpenCode) FallbackPath() string { return "/opt/homebrew/bin/opencode" }
