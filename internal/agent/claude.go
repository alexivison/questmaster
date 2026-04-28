package agent

import (
	"context"
	"fmt"

	"github.com/anthropics/ai-party/tools/party-cli/internal/config"
	"github.com/anthropics/ai-party/tools/party-cli/internal/tmux"
)

const claudeMasterPrompt = `This is a **master session**. You are an orchestrator, not an implementor.
HARD RULES: (1) Never Edit/Write production code — delegate all changes to workers.
(2) Spawn workers with party-cli spawn [title] or /party-dispatch; when overriding the primary with --primary <name>, you must also pass --companion <other-agent> (different from primary) or --no-companion, because leaving the default companion in place can fail if it matches the new primary. Relay follow-up instructions with party-cli relay <worker-id> "message", broadcast to all workers with party-cli broadcast "message", inspect workers with party-cli workers or party-cli read <worker-id>, and require workers to report back via party-cli report from the worker session. Master sessions have no companion pane (the sidebar shows the tracker); all delegation goes through workers, so do not attempt tmux-companion dispatch from the master.
(3) Investigation (Read/Grep/Glob/read-only Bash) is fine. See party-dispatch only for multi-item orchestration.
(4) MUST critically review every worker report before accepting completion: re-read scope, inspect the diff/PR, and run targeted Read/Grep/Bash spot-checks to verify requirements were actually met. Challenge unsubstantiated "done" claims and require evidence such as file:line references, command output, or PR links.`

const claudeStandalonePrompt = `This is a standalone party session. You are in a party session with a companion in the sidebar and no parent master session.
HARD RULES: (1) Work directly in this session; there is no master to report back to.
(2) Use the role-aware tmux transport only; dispatch the companion via ~/.claude/skills/agent-transport/scripts/tmux-companion.sh when you need review, planning, or parallel investigation.
(3) Coordination: party-cli read <session-id> inspects any session; party-cli workers <master-id> and party-cli broadcast <master-id> "msg" require an explicit master ID (no auto-discovery from a standalone session). If you later need workers, convert this session to a master with party-cli promote <session-id>.`

const claudeWorkerPrompt = `This is a worker session. You are a worker in a party session, not the orchestrator.
HARD RULES: (1) Work the task in front of you; do not orchestrate or spawn sub-workers.
(2) When you have a result for the master, report back via party-cli report "<result>" from this worker session.
(3) Worker tool cheatsheet: use party-cli report to reply to the master, party-cli read <session-id> when asked to inspect another session, and party-cli list for a session overview. Workers may have a companion pane depending on how they were spawned (--companion <agent> attaches one; --no-companion does not) — when present, dispatch the companion via ~/.claude/skills/agent-transport/scripts/tmux-companion.sh for review, planning, or parallel investigation; the script reports COMPANION_NOT_AVAILABLE if there is no companion pane in this session. (Master sessions never have a companion pane.)`

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
		cmd += " --effort high"
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
