package agent

import (
	"context"
	"fmt"
	"strings"
)

// SessionRole identifies the session type that determines the system prompt.
type SessionRole int

const (
	RoleStandalone SessionRole = iota
	RoleMaster
	RoleWorker
)

// TmuxClient is the subset of tmux.Client used by agent providers.
type TmuxClient interface {
	UnsetEnvironment(ctx context.Context, session, key string) error
}

// Agent represents any CLI coding agent that can run in a tmux pane.
type Agent interface {
	Name() string
	DisplayName() string
	// Description is a one-line blurb of what the harness is good for, used to
	// assemble the master prompt's harness guide. Each agent owns its own copy
	// in its provider source file; return "" to omit it from the guide.
	Description() string
	Binary() string

	BuildCmd(opts CmdOpts) string
	ResumeKey() string
	ResumeFileName() string
	EnvVar() string
	MasterPrompt() string
	StandalonePrompt() string
	WorkerPrompt() string

	FilterPaneLines(raw string, max int) []string

	PreLaunchSetup(ctx context.Context, client TmuxClient, session string) error
	BinaryEnvVar() string
	FallbackPath() string
}

// CmdOpts controls agent launch command construction.
//
// Prompt is an initial user-turn message injected after launch (what the
// user would type first). SystemBrief is appended after the standalone or
// worker system prompt so rare session-specific overrides still load as
// persistent identity rather than conversational input.
type CmdOpts struct {
	Binary      string
	AgentPath   string
	ResumeID    string
	Prompt      string
	SystemBrief string
	Title       string
	Role        SessionRole
	// Model is an explicit per-spawn model override. When empty, providers apply
	// their role default through resolveModel.
	Model string
	// ReasoningEffort is an explicit per-spawn reasoning override. When empty,
	// providers retain their hardcoded role default.
	ReasoningEffort string
}

var reasoningEfforts = map[string]string{
	"claude": "low,medium,high,xhigh,max",
	"codex":  "minimal,low,medium,high,xhigh",
	"pi":     "off,minimal,low,medium,high,xhigh",
}

// ValidateReasoningEffort rejects values that the selected harness cannot
// launch. Model-specific validation remains with the native harness.
func ValidateReasoningEffort(provider, model, effort string) error {
	if effort == "" {
		return nil
	}

	if provider == "opencode" {
		return validateOpenCodeReasoningEffort(model, effort)
	}

	supported, ok := reasoningEfforts[provider]
	if !ok {
		return fmt.Errorf("--reasoning-effort is unsupported for agent %q", provider)
	}
	if provider == "codex" && (model == "gpt-5.6-sol" || model == "gpt-5.6-terra") {
		supported += ",max,ultra"
	}
	if strings.Contains(","+supported+",", ","+effort+",") {
		return nil
	}
	return fmt.Errorf("invalid --reasoning-effort %q for %s (supported: %s)", effort, provider, strings.ReplaceAll(supported, ",", ", "))
}

func validateOpenCodeReasoningEffort(model, effort string) error {
	if model == "" {
		model = openCodeWorkerGPTModel
	}
	provider, _, ok := strings.Cut(strings.ToLower(model), "/")
	if !ok {
		return fmt.Errorf("invalid OpenCode model %q for --reasoning-effort (expected provider/model)", model)
	}

	supported := map[string]string{
		"openai":    "off,none,minimal,low,medium,high,xhigh",
		"anthropic": "high,max",
	}[provider]
	if supported == "" {
		return fmt.Errorf("--reasoning-effort for OpenCode requires a built-in openai/* or anthropic/* model, got %q", model)
	}
	if strings.Contains(","+supported+",", ","+effort+",") {
		return nil
	}
	return fmt.Errorf("invalid --reasoning-effort %q for OpenCode model %q (supported: %s)", effort, model, strings.ReplaceAll(supported, ",", ", "))
}

// resolveModel applies the per-role model policy: an explicit opts.Model
// override always wins; otherwise master gets masterDefault and worker/
// standalone get workerDefault.
func resolveModel(opts CmdOpts, workerDefault, masterDefault string) string {
	if opts.Model != "" {
		return opts.Model
	}
	if opts.Role == RoleMaster {
		return masterDefault
	}
	return workerDefault
}

func joinSystemPrompt(base, brief string) string {
	if brief == "" {
		return base
	}
	if base == "" {
		return brief
	}
	return base + "\n\n" + brief
}

func systemPromptForRole(role SessionRole, master, standalone, worker, brief string) string {
	switch role {
	case RoleMaster:
		return master
	case RoleWorker:
		return joinSystemPrompt(worker, brief)
	case RoleStandalone:
		fallthrough
	default:
		return joinSystemPrompt(standalone, brief)
	}
}
