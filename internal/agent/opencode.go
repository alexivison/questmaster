package agent

import (
	"fmt"

	"github.com/alexivison/questmaster/internal/config"
)

const (
	defaultOpenCodeModel = "opencode/big-pickle"

	// OpenCode role agent names installed by the hooks.OpenCodeInstaller and
	// selected by OpenCode.BuildCmd.
	OpenCodeMasterAgentName     = "questmaster-master"
	OpenCodeStandaloneAgentName = "questmaster-standalone"
	OpenCodeWorkerAgentName     = "questmaster-worker"
)

var openCodeSpec = Spec{
	Name:           "opencode",
	DisplayName:    "OpenCode",
	Description:    "OpenCode TUI harness with plugin-backed state tracking once the OpenCode bridge is installed",
	DefaultCLI:     "opencode",
	ResumeKey:      "opencode_session_id",
	ResumeFileName: "opencode-session-id",
	EnvVar:         "OPENCODE_SESSION_ID",
	BinaryEnvVar:   "OPENCODE_BIN",
	FallbackPath:   "/opt/homebrew/bin/opencode",
	State:          StatePlugin,
}

// OpenCode implements the built-in OpenCode provider.
//
// OpenCode 1.17.11 has proven TUI support for --agent, --prompt, --model, and
// --session. It does not expose a proven role/system prompt CLI flag, so
// Questmaster role prompts are represented by role-specific OpenCode agent
// names installed by hooks.OpenCodeInstaller.
type OpenCode struct {
	base
	model         string
	openCodeAgent string
}

// NewOpenCode constructs an OpenCode provider from config.
func NewOpenCode(cfg AgentConfig) *OpenCode {
	model := cfg.Model
	if model == "" {
		model = defaultOpenCodeModel
	}
	return &OpenCode{
		base:          newBase(openCodeSpec, cfg),
		model:         model,
		openCodeAgent: cfg.OpenCodeAgent,
	}
}

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
