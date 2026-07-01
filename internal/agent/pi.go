package agent

import (
	"fmt"

	"github.com/alexivison/questmaster/internal/config"
)

// piWorkerModel routes pi workers to a cheap openai tier (pi defaults to the
// google provider). Verified against the local pi: `pi --list-models
// openai/gpt-5.4` resolves to a real model with thinking support and configured
// creds. Workers also request `--thinking xhigh` (cheap model + max reasoning).
const piWorkerModel = "openai/gpt-5.4"

var piSpec = Spec{
	Name:           "pi",
	DisplayName:    "Pi",
	Description:    "lightweight and fast; good for small, well-scoped tasks",
	DefaultCLI:     "pi",
	ResumeKey:      "pi_session_id",
	ResumeFileName: "pi-session-id",
	EnvVar:         "PI_SESSION_ID",
	BinaryEnvVar:   "PI_BIN",
	FallbackPath:   "/opt/homebrew/bin/pi",
	State:          StateSidecar,
}

// Pi implements the built-in Pi provider.
//
// Structured Pi read output is handled by internal/message via hook state;
// FilterPaneLines remains the generic fallback for other callers.
type Pi struct {
	base
}

// NewPi constructs a Pi provider from config.
func NewPi(cfg AgentConfig) *Pi {
	return &Pi{base: newBase(piSpec, cfg)}
}

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
	if model := resolveModel(opts, piWorkerModel); model != "" {
		cmd += " --model " + config.ShellQuote(model)
	}
	switch opts.Role {
	case RoleMaster:
		cmd += " --thinking high"
	case RoleWorker:
		cmd += " --thinking xhigh"
	}
	if opts.ResumeID != "" {
		cmd += " --session " + config.ShellQuote(opts.ResumeID)
	}
	if opts.Prompt != "" {
		cmd += " " + config.ShellQuote(opts.Prompt)
	}
	return cmd
}
