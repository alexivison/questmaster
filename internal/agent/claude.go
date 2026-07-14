package agent

import (
	"context"
	"fmt"

	"github.com/alexivison/questmaster/internal/config"
)

const claudeDisableTipsSettings = `{"spinnerTipsEnabled":false}`

const (
	// The aliases auto-track the latest Claude models, so they needn't be bumped by id.
	claudeSonnetModel = "sonnet"
	claudeFableModel  = "fable"
)

var claudeSpec = Spec{
	Name:           "claude",
	DisplayName:    "Claude",
	Description:    "general-purpose coding and multi-step orchestration; a strong default",
	DefaultCLI:     "claude",
	ResumeKey:      "claude_session_id",
	ResumeFileName: "claude-session-id",
	EnvVar:         "CLAUDE_SESSION_ID",
	BinaryEnvVar:   "CLAUDE_BIN",
	FallbackPath:   "~/.local/bin/claude",
}

// Claude implements the built-in Claude provider.
type Claude struct {
	base
}

// NewClaude constructs a Claude provider from config.
func NewClaude(cfg AgentConfig) *Claude {
	return &Claude{base: newBase(claudeSpec, cfg)}
}

func (c *Claude) BuildCmd(opts CmdOpts) string {
	binary := opts.Binary
	if binary == "" {
		binary = c.Binary()
	}

	cmd := fmt.Sprintf("export PATH=%s; unset CLAUDECODE; exec %s --permission-mode bypassPermissions",
		config.ShellQuote(opts.AgentPath), config.ShellQuote(binary))
	cmd += " --settings " + config.ShellQuote(claudeDisableTipsSettings)
	if opts.ReasoningEffort == "" {
		cmd += " --effort xhigh"
	} else {
		cmd += " --effort " + config.ShellQuote(opts.ReasoningEffort)
	}
	model := opts.Model
	if model == "" {
		switch opts.Role {
		case RoleMaster:
			model = claudeFableModel
		case RoleWorker, RoleStandalone:
			model = claudeSonnetModel
		}
	}
	if model != "" {
		cmd += " --model " + config.ShellQuote(model)
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

// PreLaunchSetup clears CLAUDECODE so a nested Claude launch starts clean. It
// overrides the no-op base behaviour.
func (c *Claude) PreLaunchSetup(ctx context.Context, client TmuxClient, session string) error {
	if client == nil {
		return nil
	}
	_ = client.UnsetEnvironment(ctx, "", "CLAUDECODE")
	_ = client.UnsetEnvironment(ctx, session, "CLAUDECODE")
	return nil
}
