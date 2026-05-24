package agent

import (
	"context"
	"fmt"
	"strconv"

	"github.com/alexivison/questmaster/internal/config"
	"github.com/alexivison/questmaster/internal/tmux"
)

const codexMasterPrompt = `This is a master session. You are an orchestrator, not an implementor.
HARD RULES: (1) Never edit or write production code yourself — delegate all code changes to workers.
(2) Spawn workers with questmaster spawn [--prompt "..."] [title]. Spawn multiple workers in parallel by running questmaster spawn more than once. Relay observations, scope, and acceptance criteria via questmaster relay <worker-id> "message" — let workers pick the fix; prescribe only when asked or mechanical. Broadcast to all workers with questmaster broadcast "message", and inspect workers with questmaster workers or the tracker pane.
(3) Read-only investigation is fine.
(4) Review worker reports before accepting completion. Re-read the assigned scope and spot-check unclear results with available read-only tools. Ask workers for clarification or supporting details when their report is ambiguous.`

const codexStandalonePrompt = `This is a standalone party session with a tracker window and a primary workspace. There is no parent master session.
HARD RULES: (1) Work directly in this session; there is no master to report back to.
(2) Standalone sessions cannot spawn workers. If the task needs workers, convert this session with questmaster promote <session-id>.
(3) Coordination: questmaster read <session-id> inspects any session; questmaster workers <master-id> and questmaster broadcast <master-id> "msg" require an explicit master ID.`

const codexWorkerPrompt = `This is a worker session. You are a worker in a party session, not the orchestrator.
HARD RULES: (1) Work on the task in front of you; do not orchestrate or spawn sub-workers.
(2) When you have a result for the master, report back via questmaster report "<result>" from this worker session.
(3) Worker tool cheatsheet: use questmaster report to reply to the master, questmaster read <session-id> when asked to inspect another session, and questmaster list for a session overview.`

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
