package agent

import (
	"fmt"
	"strconv"

	"github.com/alexivison/questmaster/internal/config"
)

// codexWorkerModel is the cheaper tier codex workers default to (token-cost
// lever). Verified against codex-cli 0.142.4: `--model` is the flag and
// "gpt-5.4" is a real model id (default is "gpt-5.5"); upgrade the id here when
// the tier ladder shifts.
const codexWorkerModel = "gpt-5.4"

// codexWorkerReasoning bumps worker reasoning to the max tier (cheap model +
// high reasoning = quality-per-dollar). Set via the `model_reasoning_effort`
// config key; "xhigh" is verified valid against codex-cli 0.142.4 (it is the
// active default in ~/.codex/config.toml). Worker role only — master/standalone
// keep whatever their own config selects.
const codexWorkerReasoning = "xhigh"

var codexSpec = Spec{
	Name:           "codex",
	DisplayName:    "Codex",
	Description:    "reliable general-purpose coding with sandboxed execution",
	DefaultCLI:     "codex",
	ResumeKey:      "codex_thread_id",
	ResumeFileName: "codex-thread-id",
	EnvVar:         "CODEX_THREAD_ID",
	BinaryEnvVar:   "CODEX_BIN",
	FallbackPath:   "/opt/homebrew/bin/codex",
	Filter:         filterCodex,
}

// Codex implements the built-in Codex provider.
type Codex struct {
	base
}

// NewCodex constructs a Codex provider from config.
func NewCodex(cfg AgentConfig) *Codex {
	return &Codex{base: newBase(codexSpec, cfg)}
}

func (c *Codex) BuildCmd(opts CmdOpts) string {
	binary := opts.Binary
	if binary == "" {
		binary = c.Binary()
	}

	cmd := fmt.Sprintf("export PATH=%s; exec %s --dangerously-bypass-approvals-and-sandbox",
		config.ShellQuote(opts.AgentPath), config.ShellQuote(binary))
	if model := resolveModel(opts, codexWorkerModel, ""); model != "" {
		cmd += " --model " + config.ShellQuote(model)
	}
	if opts.Role == RoleWorker {
		cmd += " -c " + config.ShellQuote("model_reasoning_effort="+strconv.Quote(codexWorkerReasoning))
	}
	systemPrompt := systemPromptForRole(opts.Role, c.MasterPrompt(), c.StandalonePrompt(), c.WorkerPrompt(), opts.SystemBrief)
	if systemPrompt != "" {
		cmd += " -c " + config.ShellQuote("developer_instructions="+strconv.Quote(systemPrompt))
	}
	if opts.ResumeID != "" {
		cmd += " resume " + config.ShellQuote(opts.ResumeID)
	}
	if opts.Prompt != "" {
		cmd += " " + config.ShellQuote(opts.Prompt)
	}
	return cmd
}
