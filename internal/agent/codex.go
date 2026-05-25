package agent

import (
	"context"
	"fmt"
	"strconv"

	"github.com/alexivison/questmaster/internal/config"
	"github.com/alexivison/questmaster/internal/tmux"
)

// Codex implements the built-in Codex provider.
type Codex struct {
	cli string
}

// NewCodex constructs a Codex provider from config.
func NewCodex(cfg AgentConfig) *Codex {
	cli := cfg.CLI
	if cli == "" {
		cli = "codex"
	}
	return &Codex{cli: cli}
}

func (c *Codex) Name() string        { return "codex" }
func (c *Codex) DisplayName() string { return "Codex" }
func (c *Codex) Binary() string      { return c.cli }

func (c *Codex) BuildCmd(opts CmdOpts) string {
	binary := opts.Binary
	if binary == "" {
		binary = c.Binary()
	}

	cmd := fmt.Sprintf("export PATH=%s; exec %s --dangerously-bypass-approvals-and-sandbox",
		config.ShellQuote(opts.AgentPath), config.ShellQuote(binary))
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

func (c *Codex) ResumeKey() string      { return "codex_thread_id" }
func (c *Codex) ResumeFileName() string { return "codex-thread-id" }
func (c *Codex) EnvVar() string         { return "CODEX_THREAD_ID" }
func (c *Codex) MasterPrompt() string     { return masterPrompt }
func (c *Codex) StandalonePrompt() string { return standalonePrompt }
func (c *Codex) WorkerPrompt() string     { return workerPrompt }

func (c *Codex) FilterPaneLines(raw string, max int) []string {
	return tmux.FilterCodexLines(raw, max)
}

func (c *Codex) PreLaunchSetup(_ context.Context, _ TmuxClient, _ string) error {
	return nil
}

func (c *Codex) BinaryEnvVar() string { return "CODEX_BIN" }
func (c *Codex) FallbackPath() string { return "/opt/homebrew/bin/codex" }
