package agent

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	"github.com/anthropics/ai-party/tools/party-cli/internal/config"
	"github.com/anthropics/ai-party/tools/party-cli/internal/tmux"
)

const claudeMasterPrompt = "This is a **master session**. Thou art an orchestrator, not an implementor. " +
	"HARD RULES: (1) Never Edit/Write production code — delegate all changes to workers. " +
	"(2) Spawn workers with `party-cli spawn [title]` or `/party-dispatch`; relay follow-up instructions with `party-cli relay <worker-id> \"message\"`, inspect workers with `party-cli workers` or `party-cli read <worker-id>`, and require workers to report back via `party-cli report` from the worker session. " +
	"(3) Investigation (Read/Grep/Glob/read-only Bash) is fine. " +
	"See `party-dispatch` only for multi-item orchestration."

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
	if opts.Master {
		cmd += " --effort high"
		cmd += " --append-system-prompt " + config.ShellQuote(c.MasterPrompt())
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
func (c *Claude) StateFileName() string  { return "claude-state.json" }

func (c *Claude) ReadState(runtimeDir string) (AgentState, error) {
	path := filepath.Join(runtimeDir, c.StateFileName())
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return AgentState{State: "offline"}, nil
		}
		return AgentState{}, fmt.Errorf("read claude state: %w", err)
	}
	if len(data) == 0 {
		return AgentState{State: "offline"}, nil
	}

	var payload struct {
		State string `json:"state"`
	}
	if err := json.Unmarshal(data, &payload); err != nil || payload.State == "" {
		return AgentState{State: "offline"}, nil
	}
	return AgentState{State: payload.State}, nil
}

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
