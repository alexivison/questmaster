package agent

import (
	"context"
	"fmt"

	"github.com/alexivison/questmaster/internal/config"
	"github.com/alexivison/questmaster/internal/tmux"
)

const claudeMasterPrompt = `This is a **master session**. You are an orchestrator, not an implementor.
HARD RULES: (1) Never Edit/Write production code — delegate all changes to workers.
(2) Spawn workers with questmaster spawn [title]. Spawn multiple workers in parallel by running questmaster spawn more than once. Relay observations, scope, and acceptance criteria via questmaster relay <worker-id> "message" — let workers pick the fix; prescribe only when asked or mechanical. Broadcast to all workers with questmaster broadcast "message", inspect workers with questmaster workers or questmaster read <worker-id>, and require workers to report back via questmaster report from the worker session.
(3) Investigation (Read/Grep/Glob/read-only Bash) is fine.
(4) Review worker reports before accepting completion. Re-read the assigned scope and spot-check unclear results with available read-only tools. Ask workers for clarification or supporting details when their report is ambiguous.`

const claudeStandalonePrompt = `This is a standalone party session with a tracker window and a primary workspace. There is no parent master session.
HARD RULES: (1) Work directly in this session; there is no master to report back to.
(2) Standalone sessions cannot spawn workers. If the task needs workers, convert this session with questmaster promote <session-id>.
(3) Coordination: questmaster read <session-id> inspects any session; questmaster workers <master-id> and questmaster broadcast <master-id> "msg" require an explicit master ID.`

const claudeWorkerPrompt = `This is a worker session. You are a worker in a party session, not the orchestrator.
HARD RULES: (1) Work the task in front of you; do not orchestrate or spawn sub-workers.
(2) When you have a result for the master, report back via questmaster report "<result>" from this worker session.
(3) Worker tool cheatsheet: use questmaster report to reply to the master, questmaster read <session-id> when asked to inspect another session, and questmaster list for a session overview.`

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
func (c *Claude) Binary() string      { return c.cli }

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

func (c *Claude) ResumeKey() string      { return "claude_session_id" }
func (c *Claude) ResumeFileName() string { return "claude-session-id" }
func (c *Claude) EnvVar() string         { return "CLAUDE_SESSION_ID" }
func (c *Claude) MasterPrompt() string   { return claudeMasterPrompt }
func (c *Claude) StandalonePrompt() string {
	return claudeStandalonePrompt
}
func (c *Claude) WorkerPrompt() string { return claudeWorkerPrompt }

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
