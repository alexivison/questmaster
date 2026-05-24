package agent

import (
	"context"
	"fmt"

	"github.com/alexivison/questmaster/internal/config"
	"github.com/alexivison/questmaster/internal/tmux"
)

const piMasterPrompt = `This is a **master session**. You are an orchestrator, not an implementor.
HARD RULES: (1) Never Edit/Write production code — delegate all changes to workers.
(2) Spawn workers with questmaster spawn [title]. Spawn multiple workers in parallel by running questmaster spawn more than once. Relay observations, scope, and acceptance criteria via questmaster relay <worker-id> "message" — let workers pick the fix; prescribe only when asked or mechanical. Broadcast to all workers with questmaster broadcast "message", inspect workers with questmaster workers or questmaster read <worker-id>, and require workers to report back via questmaster report from the worker session.
(3) Investigation (Read/Grep/Glob/read-only Bash) is fine.
(4) Review worker reports before accepting completion. Re-read the assigned scope and spot-check unclear results with available read-only tools. Ask workers for clarification or supporting details when their report is ambiguous.`

const piStandalonePrompt = `This is a standalone party session with a tracker window and a primary workspace. There is no parent master session.
HARD RULES: (1) Work directly in this session; there is no master to report back to.
(2) Standalone sessions cannot spawn workers. If the task needs workers, convert this session with questmaster promote <session-id>.
(3) Coordination: questmaster read <session-id> inspects any session; questmaster workers <master-id> and questmaster broadcast <master-id> "msg" require an explicit master ID.`

const piWorkerPrompt = `This is a worker session. You are a worker in a party session, not the orchestrator.
HARD RULES: (1) Work the task in front of you; do not orchestrate or spawn sub-workers.
(2) When you have a result for the master, report back via questmaster report "<result>" from this worker session.
(3) Worker tool cheatsheet: use questmaster report to reply to the master, questmaster read <session-id> when asked to inspect another session, and questmaster list for a session overview.`

// Pi implements the built-in Pi provider.
//
// Structured Pi read output is handled by internal/message via hook state;
// FilterPaneLines remains the generic fallback for other callers.
type Pi struct {
	cli string
}

// NewPi constructs a Pi provider from config.
func NewPi(cfg AgentConfig) *Pi {
	cli := cfg.CLI
	if cli == "" {
		cli = "pi"
	}
	return &Pi{cli: cli}
}

func (p *Pi) Name() string        { return "pi" }
func (p *Pi) DisplayName() string { return "Pi" }
func (p *Pi) Binary() string      { return p.cli }

func (p *Pi) BuildCmd(opts CmdOpts) string {
	binary := opts.Binary
	if binary == "" {
		binary = p.Binary()
	}

	cmd := fmt.Sprintf("export PATH=%s; exec %s",
		config.ShellQuote(opts.AgentPath), config.ShellQuote(binary))
	systemPrompt := systemPromptForRole(opts.Role, p.MasterPrompt(), p.StandalonePrompt(), p.WorkerPrompt(), opts.SystemBrief)
	if systemPrompt != "" {
		cmd += " --append-system-prompt " + config.ShellQuote(systemPrompt)
	}
	if opts.Role == RoleMaster && opts.SystemBrief != "" {
		cmd += " --append-system-prompt " + config.ShellQuote(opts.SystemBrief)
	}
	if opts.Role == RoleMaster {
		cmd += " --thinking high"
	}
	if opts.ResumeID != "" {
		cmd += " --session " + config.ShellQuote(opts.ResumeID)
	}
	if opts.Prompt != "" {
		cmd += " " + config.ShellQuote(opts.Prompt)
	}
	return cmd
}

func (p *Pi) ResumeKey() string        { return "pi_session_id" }
func (p *Pi) ResumeFileName() string   { return "pi-session-id" }
func (p *Pi) EnvVar() string           { return "PI_SESSION_ID" }
func (p *Pi) MasterPrompt() string     { return piMasterPrompt }
func (p *Pi) StandalonePrompt() string { return piStandalonePrompt }
func (p *Pi) WorkerPrompt() string     { return piWorkerPrompt }

func (p *Pi) FilterPaneLines(raw string, max int) []string {
	return tmux.FilterAgentLines(raw, max)
}

func (p *Pi) PreLaunchSetup(_ context.Context, _ TmuxClient, _ string) error {
	return nil
}

func (p *Pi) BinaryEnvVar() string { return "PI_BIN" }
func (p *Pi) FallbackPath() string { return "/opt/homebrew/bin/pi" }
