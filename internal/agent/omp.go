package agent

import (
	"fmt"

	"github.com/alexivison/questmaster/internal/config"
)

// Omp implements the built-in oh-my-pi provider.
//
// oh-my-pi (binary `omp`) is a fork of Pi with the same launch-flag surface,
// so the command construction mirrors the Pi provider. Two deliberate
// differences: (1) omp's --append-system-prompt is a last-wins scalar rather
// than a repeatable flag, so the role prompt and per-session brief are merged
// into a single value; (2) master sessions request `--thinking xhigh`, which
// omp supports (Pi tops out at the level questmaster passes it).
//
// Structured omp read output is handled by internal/message via hook state
// emitted by the activity sidecar (internal/hooks/assets/omp-activity-sidecar.ts);
// FilterPaneLines remains the generic fallback for other callers.
var ompSpec = Spec{
	Name:           "omp",
	DisplayName:    "oh-my-pi",
	Description:    "a Pi-style harness that adds a built-in LSP and an interactive debugger (breakpoints, step, inspect variables, evaluate expressions)",
	DefaultCLI:     "omp",
	ResumeKey:      "omp_session_id",
	ResumeFileName: "omp-session-id",
	EnvVar:         "OMP_SESSION_ID",
	BinaryEnvVar:   "OMP_BIN",
	FallbackPath:   "~/.local/bin/omp",
	State:          StateSidecar,
}

const ompGPTModel = "openai-codex/gpt-5.5"

type Omp struct {
	base
}

// NewOmp constructs an oh-my-pi provider from config.
func NewOmp(cfg AgentConfig) *Omp {
	return &Omp{base: newBase(ompSpec, cfg)}
}

func (o *Omp) BuildCmd(opts CmdOpts) string {
	binary := opts.Binary
	if binary == "" {
		binary = o.Binary()
	}

	cmd := fmt.Sprintf("export PATH=%s; exec %s",
		config.ShellQuote(opts.AgentPath), config.ShellQuote(binary))

	systemPrompt := systemPromptForRole(opts.Role, o.MasterPrompt(), o.StandalonePrompt(), o.WorkerPrompt(), opts.SystemBrief)
	// omp's --append-system-prompt is a last-wins scalar (args.ts stores it
	// into a single field), so unlike Claude/Pi we cannot pass a master's
	// session brief as a second flag. Merge it into the one prompt value.
	if opts.Role == RoleMaster {
		systemPrompt = joinSystemPrompt(systemPrompt, opts.SystemBrief)
	}
	if systemPrompt != "" {
		cmd += " --append-system-prompt " + config.ShellQuote(systemPrompt)
	}
	if model := resolveModel(opts, ompGPTModel, ompGPTModel); model != "" {
		cmd += " --model=" + config.ShellQuote(model)
	}
	switch opts.Role {
	case RoleMaster:
		cmd += " --thinking xhigh"
	case RoleWorker:
		cmd += " --thinking=high"
	case RoleStandalone:
		cmd += " --thinking=xhigh"
	}
	if opts.ResumeID != "" {
		cmd += " --resume " + config.ShellQuote(opts.ResumeID)
	}
	if opts.Prompt != "" {
		cmd += " " + config.ShellQuote(opts.Prompt)
	}
	return cmd
}
