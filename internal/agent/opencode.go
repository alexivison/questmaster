package agent

import (
	"fmt"
	"os/exec"
	"strconv"
	"strings"

	"github.com/alexivison/questmaster/internal/config"
)

const (
	defaultOpenCodeModel = "opencode/big-pickle"

	// --variant is exposed by OpenCode 1.17.15+ through `opencode run
	// --interactive`, its direct interactive split-footer mode. It keeps the
	// configured role agent and plugin bridge without shared-state mutation.
	openCodeReasoningMinVersion = "1.17.15"
	openCodeWorkerGPTModel      = "openai/gpt-5.4"
	openCodeMasterGPTModel      = "openai/gpt-5.5"

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

// ValidateOpenCodeReasoningVersion ensures the per-launch variant surface is
// available before Questmaster creates the tmux session.
func ValidateOpenCodeReasoningVersion(binary string) error {
	output, err := exec.Command(binary, "--version").Output()
	if err != nil {
		return fmt.Errorf("check OpenCode version for --reasoning-effort: %w", err)
	}
	version := strings.TrimPrefix(strings.TrimSpace(string(output)), "v")
	parts := strings.Split(version, ".")
	if len(parts) != 3 {
		return fmt.Errorf("could not parse OpenCode version %q for --reasoning-effort (requires %s+)", version, openCodeReasoningMinVersion)
	}
	for i, want := range [...]int{1, 17, 15} {
		got, err := strconv.Atoi(strings.SplitN(parts[i], "-", 2)[0])
		if err != nil {
			return fmt.Errorf("could not parse OpenCode version %q for --reasoning-effort (requires %s+)", version, openCodeReasoningMinVersion)
		}
		if got > want {
			return nil
		}
		if got < want {
			return fmt.Errorf("OpenCode %s does not support --reasoning-effort; requires %s+", version, openCodeReasoningMinVersion)
		}
	}
	return nil
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

	// Precedence: explicit override > role default with
	// one opencode-specific twist: standalone honors an explicitly-configured
	// model. opencode's --model is required, so standalone uses the worker tier
	// by default; a user's custom AgentConfig.Model (anything other than the
	// baked-in big-pickle default) still pins standalone.
	model := resolveModel(opts, openCodeWorkerGPTModel, openCodeMasterGPTModel)
	if opts.Role == RoleStandalone && opts.Model == "" && o.model != "" && o.model != defaultOpenCodeModel {
		model = o.model
	}

	cmd := fmt.Sprintf("export PATH=%s; exec %s",
		config.ShellQuote(opts.AgentPath),
		config.ShellQuote(binary))
	if opts.ReasoningEffort != "" {
		cmd += " run --interactive"
	}
	cmd += " --model " + config.ShellQuote(model)
	cmd += " --agent " + config.ShellQuote(o.agentName(opts.Role))
	if opts.ReasoningEffort != "" {
		variant := opts.ReasoningEffort
		if variant == "off" {
			variant = "none"
		}
		cmd += " --variant " + config.ShellQuote(variant)
	}
	if opts.ResumeID != "" {
		cmd += " --session " + config.ShellQuote(opts.ResumeID)
	}
	if opts.Prompt != "" {
		if opts.ReasoningEffort != "" {
			cmd += " " + config.ShellQuote(opts.Prompt)
		} else {
			cmd += " --prompt " + config.ShellQuote(opts.Prompt)
		}
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
