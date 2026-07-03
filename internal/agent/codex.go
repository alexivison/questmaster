package agent

import (
	"fmt"
	"strconv"

	"github.com/alexivison/questmaster/internal/config"
)

const (
	codexGPTModel        = "gpt-5.5"
	codexMasterReasoning = "xhigh"
	codexWorkerReasoning = "high"
)

var codexSpec = Spec{
	Name:           "codex",
	DisplayName:    "Codex",
	Description:    "reliable general-purpose coding with strong codebase navigation",
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
	if model := resolveModel(opts, codexGPTModel, codexGPTModel); model != "" {
		cmd += " --model " + config.ShellQuote(model)
	}
	switch opts.Role {
	case RoleWorker:
		cmd += " -c " + config.ShellQuote("model_reasoning_effort="+strconv.Quote(codexWorkerReasoning))
	case RoleMaster, RoleStandalone:
		cmd += " -c " + config.ShellQuote("model_reasoning_effort="+strconv.Quote(codexMasterReasoning))
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
