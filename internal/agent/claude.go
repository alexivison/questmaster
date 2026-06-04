package agent

import (
	"context"
	"fmt"

	"github.com/alexivison/questmaster/internal/config"
	"github.com/alexivison/questmaster/internal/tmux"
)

const claudeDisableTipsSettings = `{"spinnerTipsEnabled":false}`

// Claude implements the built-in Claude provider.
type Claude struct {
	cli string
}

// NewClaude constructs a Claude provider from config.
func NewClaude(cfg AgentConfig) *Claude {
	cli := cfg.CLI
	if cli == "" {
		cli = "claude"
	}
	return &Claude{cli: cli}
}

func (c *Claude) Name() string        { return "claude" }
func (c *Claude) DisplayName() string { return "Claude" }
func (c *Claude) Description() string {
	return "general-purpose coding and multi-step orchestration; a strong default"
}
func (c *Claude) Binary() string { return c.cli }

func (c *Claude) BuildCmd(opts CmdOpts) string {
	binary := opts.Binary
	if binary == "" {
		binary = c.Binary()
	}

	cmd := fmt.Sprintf("export PATH=%s; unset CLAUDECODE; exec %s --permission-mode bypassPermissions",
		config.ShellQuote(opts.AgentPath), config.ShellQuote(binary))
	cmd += " --settings " + config.ShellQuote(claudeDisableTipsSettings)
	if opts.Role == RoleMaster {
		cmd += " --effort max"
	} else {
		cmd += " --effort xhigh"
	}
	systemPrompt := systemPromptForRole(opts.Role, c.MasterPrompt(), c.StandalonePrompt(), c.WorkerPrompt(), opts.SystemBrief)
	if systemPrompt != "" {
		cmd += " --append-system-prompt " + config.ShellQuote(systemPrompt)
	}
	if opts.Role == RoleMaster && opts.SystemBrief != "" {
		cmd += " --append-system-prompt " + config.ShellQuote(opts.SystemBrief)
	}
	if opts.Title != "" {
		cmd += " --name " + config.ShellQuote(opts.Title)
	}
	if opts.ResumeID != "" {
		cmd += " --resume " + config.ShellQuote(opts.ResumeID)
	}
	if opts.Prompt != "" {
		cmd += " -- " + config.ShellQuote(opts.Prompt)
	}
	return cmd
}

func (c *Claude) ResumeKey() string        { return "claude_session_id" }
func (c *Claude) ResumeFileName() string   { return "claude-session-id" }
func (c *Claude) EnvVar() string           { return "CLAUDE_SESSION_ID" }
func (c *Claude) MasterPrompt() string     { return masterPromptWithGuide() }
func (c *Claude) StandalonePrompt() string { return standalonePrompt }
func (c *Claude) WorkerPrompt() string     { return workerPrompt }

func (c *Claude) FilterPaneLines(raw string, max int) []string {
	return tmux.FilterAgentLines(raw, max)
}

func (c *Claude) PreLaunchSetup(ctx context.Context, client TmuxClient, session string) error {
	if client == nil {
		return nil
	}
	_ = client.UnsetEnvironment(ctx, "", "CLAUDECODE")
	_ = client.UnsetEnvironment(ctx, session, "CLAUDECODE")
	return nil
}

func (c *Claude) BinaryEnvVar() string { return "CLAUDE_BIN" }
func (c *Claude) FallbackPath() string { return "~/.local/bin/claude" }
