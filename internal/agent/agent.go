package agent

import (
	"context"
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
