package agent

import (
	"fmt"
	"strconv"

	"github.com/alexivison/questmaster/internal/config"
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
	Models: ModelPolicy{
		Sources: []ModelSource{{Catalog: "openai"}},
	},
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

	args := "--dangerously-bypass-approvals-and-sandbox"
	if opts.Model != "" {
		args += " --model " + config.ShellQuote(opts.Model)
	}
	if opts.ReasoningEffort != "" {
		args += " -c " + config.ShellQuote("model_reasoning_effort="+strconv.Quote(opts.ReasoningEffort))
	}
	systemPrompt := systemPromptForRole(opts.Role, c.MasterPrompt(), c.StandalonePrompt(), c.WorkerPrompt(), opts.SystemBrief)
	if systemPrompt != "" {
		args += " -c " + config.ShellQuote("developer_instructions="+strconv.Quote(systemPrompt))
	}
	if opts.ResumeID != "" {
		args += " resume " + config.ShellQuote(opts.ResumeID)
	}
	if opts.Prompt != "" {
		args += " -- " + config.ShellQuote(opts.Prompt)
	}
	quotedBinary := config.ShellQuote(binary)
	return fmt.Sprintf("export PATH=%s; if %s app-server daemon start >/dev/null 2>&1; then set -- --remote unix://; else set --; fi; exec %s \"$@\" %s",
		config.ShellQuote(opts.AgentPath), quotedBinary, quotedBinary, args)
}
