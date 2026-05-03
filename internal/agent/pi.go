package agent

import (
	"context"
	"fmt"

	"github.com/anthropics/ai-party/tools/party-cli/internal/config"
	"github.com/anthropics/ai-party/tools/party-cli/internal/tmux"
)

// Pi prompts mirror Claude's wording but are owned by Pi so future copy can
// diverge without touching Claude. Transport script paths point at the Claude
// install path (~/.claude/skills/agent-transport/scripts/...) as a Phase-1.5
// interim: Pi panes have no ~/.pi/skills/ install path yet, but ~/.claude
// always exists in any party install (Claude is the default primary) and the
// scripts run via bash regardless of the invoking agent. A follow-up should
// add ~/.pi/skills/ symlinks if Pi gets first-class skill discovery.
const piMasterPrompt = `This is a **master session**. You are an orchestrator, not an implementor.
HARD RULES: (1) Never Edit/Write production code — delegate all changes to workers.
(2) Spawn workers with party-cli spawn [title] or /party-dispatch; when overriding the primary with --primary <name>, you must also pass --companion <other-agent> (different from primary) or --no-companion, because leaving the default companion in place can fail if it matches the new primary. Relay follow-up instructions with party-cli relay <worker-id> "message", broadcast to all workers with party-cli broadcast "message", inspect workers with party-cli workers or party-cli read <worker-id>, and require workers to report back via party-cli report from the worker session. Master sessions have no companion pane (the sidebar shows the tracker); all delegation goes through workers, so do not attempt tmux-companion dispatch from the master.
(3) Investigation (Read/Grep/Glob/read-only Bash) is fine. See party-dispatch only for multi-item orchestration.
(4) MUST critically review every worker report before accepting completion: re-read scope, inspect the diff/PR, and run targeted Read/Grep/Bash spot-checks to verify requirements were actually met. Challenge unsubstantiated "done" claims and require evidence such as file:line references, command output, or PR links.`

const piStandalonePrompt = `This is a standalone party session. You are in a party session with a companion in the sidebar and no parent master session.
HARD RULES: (1) Work directly in this session; there is no master to report back to.
(2) Use the role-aware tmux transport only; dispatch the companion via ~/.claude/skills/agent-transport/scripts/tmux-companion.sh when you need review, planning, or parallel investigation.
(3) Coordination: party-cli read <session-id> inspects any session; party-cli workers <master-id> and party-cli broadcast <master-id> "msg" require an explicit master ID (no auto-discovery from a standalone session). If you later need workers, convert this session to a master with party-cli promote <session-id>.`

const piWorkerPrompt = `This is a worker session. You are a worker in a party session, not the orchestrator.
HARD RULES: (1) Work the task in front of you; do not orchestrate or spawn sub-workers.
(2) When you have a result for the master, report back via party-cli report "<result>" from this worker session.
(3) Worker tool cheatsheet: use party-cli report to reply to the master, party-cli read <session-id> when asked to inspect another session, and party-cli list for a session overview. Workers may have a companion pane depending on how they were spawned (--companion <agent> attaches one; --no-companion does not) — when present, dispatch the companion via ~/.claude/skills/agent-transport/scripts/tmux-companion.sh for review, planning, or parallel investigation; the script reports COMPANION_NOT_AVAILABLE if there is no companion pane in this session. (Master sessions never have a companion pane.)`

// Pi implements the built-in Pi provider stub.
//
// Phase 1 stub: provider registers and BuildCmd compiles, but FilterPaneLines
// returns the generic agent filter (real implementation lands in Phase 2) and
// no Pi-specific tests exist yet (Phase 4).
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
