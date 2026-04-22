package agent

import (
	"context"
	"fmt"

	"github.com/anthropics/ai-party/tools/party-cli/internal/config"
	"github.com/anthropics/ai-party/tools/party-cli/internal/tmux"
)

const claudeMasterPrompt = "This is a **master session**. You are an orchestrator, not an implementor. " +
	"HARD RULES: (1) Never Edit/Write production code — delegate all changes to workers. " +
	"(2) Spawn workers with `party-cli spawn [title]` or `/party-dispatch`; relay follow-up instructions with `party-cli relay <worker-id> \"message\"`, inspect workers with `party-cli workers` or `party-cli read <worker-id>`, and require workers to report back via `party-cli report` from the worker session. " +
	"(3) Investigation (Read/Grep/Glob/read-only Bash) is fine. " +
	"See `party-dispatch` only for multi-item orchestration."

const claudeWorkerPrompt = "This is a worker session. You are a worker in a party session, not the orchestrator. " +
	"HARD RULES: (1) Work the task in front of you; do not orchestrate or spawn sub-workers. " +
	"(2) When you have a result for the master, report back via `party-cli report \"<result>\"` from this worker session. " +
	"(3) Worker tool cheatsheet: use `party-cli report` to reply to the master, `party-cli read <session-id>` when asked to inspect another session, " +
	"and `party-cli workers` if you need a quick session list for context."

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
func (c *Claude) Binary() string      { return c.cli }

func (c *Claude) BuildCmd(opts CmdOpts) string {
	binary := opts.Binary
	if binary == "" {
		binary = c.Binary()
	}

	cmd := fmt.Sprintf("export PATH=%s; unset CLAUDECODE; exec %s --permission-mode bypassPermissions --settings %s",
		config.ShellQuote(opts.AgentPath), config.ShellQuote(binary), config.ShellQuote(`{"spinnerTipsEnabled":false}`))
	if opts.Master {
		cmd += " --effort high"
		cmd += " --append-system-prompt " + config.ShellQuote(c.MasterPrompt())
	} else {
		systemPrompt := joinSystemPrompt(c.WorkerPrompt(), opts.SystemBrief)
		if systemPrompt != "" {
			cmd += " --append-system-prompt " + config.ShellQuote(systemPrompt)
		}
	}
	if opts.Master && opts.SystemBrief != "" {
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

func (c *Claude) ResumeKey() string      { return "claude_session_id" }
func (c *Claude) ResumeFileName() string { return "claude-session-id" }
func (c *Claude) EnvVar() string         { return "CLAUDE_SESSION_ID" }
func (c *Claude) MasterPrompt() string   { return claudeMasterPrompt }
func (c *Claude) WorkerPrompt() string   { return claudeWorkerPrompt }

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
