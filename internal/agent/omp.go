package agent

import (
	"context"
	"fmt"

	"github.com/alexivison/questmaster/internal/config"
	"github.com/alexivison/questmaster/internal/tmux"
)

// Omp implements the built-in oh-my-pi provider.
//
// oh-my-pi (binary `omp`) is a fork of Pi with the same launch-flag surface,
// so the command construction mirrors the Pi provider. Two deliberate
// differences: (1) omp's --append-system-prompt is a last-wins scalar rather
// than a repeatable flag, so the role prompt and per-session brief are merged
// into a single value; (2) master sessions request `--thinking xhigh`, which
// omp supports (Pi tops out at the level questmaster passes it).
//
// Structured omp read output is handled by internal/message via hook state
// emitted by the activity sidecar (internal/hooks/assets/omp-activity-sidecar.ts);
// FilterPaneLines remains the generic fallback for other callers.
type Omp struct {
	cli string
}

// NewOmp constructs an oh-my-pi provider from config.
func NewOmp(cfg AgentConfig) *Omp {
	cli := cfg.CLI
	if cli == "" {
		cli = "omp"
	}
	return &Omp{cli: cli}
}

func (o *Omp) Name() string        { return "omp" }
func (o *Omp) DisplayName() string { return "oh-my-pi" }
func (o *Omp) Description() string {
	return "a Pi-style harness that adds a built-in LSP and an interactive debugger (breakpoints, step, inspect variables, evaluate expressions)"
}
func (o *Omp) Binary() string { return o.cli }

func (o *Omp) BuildCmd(opts CmdOpts) string {
	binary := opts.Binary
	if binary == "" {
		binary = o.Binary()
	}

	cmd := fmt.Sprintf("export PATH=%s; exec %s",
		config.ShellQuote(opts.AgentPath), config.ShellQuote(binary))

	systemPrompt := systemPromptForRole(opts.Role, o.MasterPrompt(), o.StandalonePrompt(), o.WorkerPrompt(), opts.SystemBrief)
	// omp's --append-system-prompt is a last-wins scalar (args.ts stores it
	// into a single field), so unlike Claude/Pi we cannot pass a master's
	// session brief as a second flag. Merge it into the one prompt value.
	if opts.Role == RoleMaster {
		systemPrompt = joinSystemPrompt(systemPrompt, opts.SystemBrief)
	}
	if systemPrompt != "" {
		cmd += " --append-system-prompt " + config.ShellQuote(systemPrompt)
	}
	if opts.Role == RoleMaster {
		cmd += " --thinking xhigh"
	}
	if opts.ResumeID != "" {
		cmd += " --resume " + config.ShellQuote(opts.ResumeID)
	}
	if opts.Prompt != "" {
		cmd += " " + config.ShellQuote(opts.Prompt)
	}
	return cmd
}

func (o *Omp) ResumeKey() string        { return "omp_session_id" }
func (o *Omp) ResumeFileName() string   { return "omp-session-id" }
func (o *Omp) EnvVar() string           { return "OMP_SESSION_ID" }
func (o *Omp) MasterPrompt() string     { return masterPromptWithGuide() }
func (o *Omp) StandalonePrompt() string { return standalonePrompt }
func (o *Omp) WorkerPrompt() string     { return workerPrompt }

func (o *Omp) FilterPaneLines(raw string, max int) []string {
	return tmux.FilterAgentLines(raw, max)
}

func (o *Omp) PreLaunchSetup(_ context.Context, _ TmuxClient, _ string) error {
	return nil
}

func (o *Omp) BinaryEnvVar() string { return "OMP_BIN" }
func (o *Omp) FallbackPath() string { return "~/.local/bin/omp" }
