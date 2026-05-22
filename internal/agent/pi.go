package agent

import (
	"context"
	"fmt"

	"github.com/alexivison/questmaster/internal/config"
	"github.com/alexivison/questmaster/internal/tmux"
)

// Pi prompts are owned by Pi while sharing the generic role-aware contract.
const piMasterPrompt = `This is a **master session**. You are an orchestrator, not an implementor.
HARD RULES: (1) Never Edit/Write production code — delegate all changes to workers.
(2) Spawn workers with questmaster spawn [title] or /party-dispatch. Workers have no companion by default; pass --companion <agent> to attach one. If --primary X --companion X (or any path where the resolved primary equals the resolved companion) the spawn errors before any tmux work — pick a different companion. Relay observations (file:line, log excerpts, scope, acceptance) via questmaster relay <worker-id> "message" — let workers pick the fix; prescribe only when asked or mechanical. Broadcast to all workers with questmaster broadcast "message", inspect workers with questmaster workers or questmaster read <worker-id>, and require workers to report back via questmaster report from the worker session. Master sessions have no companion pane (the sidebar shows the tracker); all delegation goes through workers, so do not use questmaster transport from the master. It errors with COMPANION_NOT_AVAILABLE.
(3) Investigation (Read/Grep/Glob/read-only Bash) is fine. See party-dispatch only for multi-item orchestration.
(4) MUST critically review every worker report before accepting completion: re-read scope, inspect the diff/PR, and run targeted Read/Grep/Bash spot-checks to verify requirements were actually met. Challenge unsubstantiated "done" claims and require evidence such as file:line references, command output, or PR links.`

const piStandalonePrompt = `This is a standalone party session. You are in a party session with a companion in the sidebar and no parent master session.
HARD RULES: (1) Work directly in this session; there is no master to report back to.
(2) Use the native role-aware transport only: run questmaster transport "your message" to send to the peer pane in this session. The command auto-routes primary to companion and companion to primary. Master sessions have no companion pane, and questmaster transport from a master errors with COMPANION_NOT_AVAILABLE.
(3) Coordination: questmaster read <session-id> inspects any session; questmaster workers <master-id> and questmaster broadcast <master-id> "msg" require an explicit master ID (no auto-discovery from a standalone session). If you later need workers, convert this session to a master with questmaster promote <session-id>.`

const piWorkerPrompt = `This is a worker session. You are a worker in a party session, not the orchestrator.
HARD RULES: (1) Work the task in front of you; do not orchestrate or spawn sub-workers.
(2) When you have a result for the master, report back via questmaster report "<result>" from this worker session.
(3) Worker tool cheatsheet: use questmaster report to reply to the master, questmaster read <session-id> when asked to inspect another session, and questmaster list for a session overview. Workers may have a companion pane depending on how they were spawned (pass --companion <agent> to attach one; omit it for a solo worker) — when present, send peer messages with questmaster transport "your message"; it auto-routes primary to companion and companion to primary. Master sessions have no companion pane, and questmaster transport from a master errors with COMPANION_NOT_AVAILABLE.`

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
