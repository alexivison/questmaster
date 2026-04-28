package agent

import (
	"context"
	"fmt"
	"strconv"

	"github.com/anthropics/ai-party/tools/party-cli/internal/config"
	"github.com/anthropics/ai-party/tools/party-cli/internal/tmux"
)

const codexMasterPrompt = `This is a master session. You are an orchestrator, not an implementor.
HARD RULES: (1) Never edit or write production code yourself — delegate all code changes to workers.
(2) Spawn workers with party-cli spawn [title] or ~/Code/ai-party/session/party-relay.sh --spawn [--prompt "..."] [title]; when overriding the primary with --primary <name>, you must also pass --companion <other-agent> (different from primary) or --no-companion, because leaving the default companion in place can fail if it matches the new primary. Relay follow-up instructions with party-cli relay <worker-id> "message", broadcast to all workers with party-cli broadcast "message", and inspect workers with party-cli workers or the tracker pane. Master sessions have no companion pane (the sidebar shows the tracker); all delegation goes through workers, so do not attempt tmux-companion dispatch from the master.
(3) Read-only investigation is fine.
(4) MUST critically review every worker report before accepting completion: re-read scope, inspect the diff/PR, and run targeted Read/Grep/Bash spot-checks to verify requirements were actually met. Challenge unsubstantiated "done" claims and require evidence such as file:line references, command output, or PR links.`

const codexStandalonePrompt = `This is a standalone party session. You are in a party session with a companion in the sidebar and no parent master session.
HARD RULES: (1) Work directly in this session; there is no master to report back to.
(2) Use the role-aware tmux transport only: if Codex is primary, dispatch the companion via ~/.codex/skills/agent-transport/scripts/tmux-companion.sh; if Codex is companion, notify the primary via ~/.codex/skills/agent-transport/scripts/tmux-primary.sh.
(3) Coordination: party-cli read <session-id> inspects any session; party-cli workers <master-id> and party-cli broadcast <master-id> "msg" require an explicit master ID (no auto-discovery from a standalone session). If you later need workers, convert this session to a master with party-cli promote <session-id>.`

const codexWorkerPrompt = `This is a worker session. You are a worker in a party session, not the orchestrator.
HARD RULES: (1) Work on the task in front of you; do not orchestrate or spawn sub-workers.
(2) When you have a result for the master, report back via party-cli report "<result>" from this worker session.
(3) Worker tool cheatsheet: use party-cli report to reply to the master, party-cli read <session-id> when asked to inspect another session, and party-cli list for a session overview. Workers may have a companion pane depending on how they were spawned (--companion <agent> attaches one; --no-companion does not) — when present, dispatch the companion via ~/.codex/skills/agent-transport/scripts/tmux-companion.sh for review, planning, or parallel investigation; the script reports COMPANION_NOT_AVAILABLE if there is no companion pane in this session. (Master sessions never have a companion pane.)`

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
func (c *Codex) MasterPrompt() string   { return codexMasterPrompt }
func (c *Codex) StandalonePrompt() string {
	return codexStandalonePrompt
}
func (c *Codex) WorkerPrompt() string { return codexWorkerPrompt }

func (c *Codex) FilterPaneLines(raw string, max int) []string {
	return tmux.FilterCodexLines(raw, max)
}

func (c *Codex) PreLaunchSetup(_ context.Context, _ TmuxClient, _ string) error {
	return nil
}

func (c *Codex) BinaryEnvVar() string { return "CODEX_BIN" }
func (c *Codex) FallbackPath() string { return "/opt/homebrew/bin/codex" }
