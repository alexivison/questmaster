package agent

import (
	"fmt"
	"os"
	"strconv"

	"github.com/alexivison/questmaster/internal/config"
)

var codexSpec = Spec{
	Name:           "codex",
	DisplayName:    "Codex",
	DefaultCLI:     "codex",
	ResumeKey:      "codex_thread_id",
	ResumeFileName: "codex-thread-id",
	EnvVar:         "CODEX_THREAD_ID",
	BinaryEnvVar:   "CODEX_BIN",
	FallbackPath:   "/opt/homebrew/bin/codex",
	Filter:         filterCodex,
	Efforts:        EffortSourceCodexCache,
	EffortModel:    EffortSourceCodexConfig,
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
	launcher := opts.LauncherBinary
	if launcher == "" {
		launcher, _ = os.Executable()
	}
	cmd := fmt.Sprintf("export PATH=%s; exec %s agent codex --binary %s",
		config.ShellQuote(opts.AgentPath), config.ShellQuote(launcher), config.ShellQuote(binary))
	settings := []string{`approval_policy="never"`, `sandbox_mode="danger-full-access"`}
	if opts.Model != "" {
		settings = append(settings, "model="+strconv.Quote(opts.Model))
	}
	if opts.ReasoningEffort != "" {
		settings = append(settings, "model_reasoning_effort="+strconv.Quote(opts.ReasoningEffort))
	}
	if prompt := systemPromptForRole(opts.Role, opts.Class, c.MasterPrompt(), c.WorkerPrompt(), opts.SystemBrief); prompt != "" {
		settings = append(settings, "developer_instructions="+strconv.Quote(prompt))
	}
	for _, setting := range settings {
		cmd += " --config " + config.ShellQuote(setting)
	}
	cmd += " --"
	if opts.ResumeID != "" {
		cmd += " resume " + config.ShellQuote(opts.ResumeID)
	}
	if opts.Prompt != "" {
		cmd += " -- " + config.ShellQuote(opts.Prompt)
	}
	return cmd
}
