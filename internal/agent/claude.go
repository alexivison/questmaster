package agent

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/anthropics/ai-party/tools/party-cli/internal/config"
	"github.com/anthropics/ai-party/tools/party-cli/internal/tmux"
)

const claudeMasterPrompt = "This is a **master session**. Thou art an orchestrator, not an implementor. " +
	"HARD RULES: (1) Never Edit/Write production code — delegate all changes to workers. " +
	"(2) Spawn workers with `party-cli spawn [title]` or `/party-dispatch`; relay follow-up instructions with `party-cli relay <worker-id> \"message\"`, inspect workers with `party-cli workers` or `party-cli read <worker-id>`, and require workers to report back via `party-cli report` from the worker session. " +
	"(3) Investigation (Read/Grep/Glob/read-only Bash) is fine. " +
	"See `party-dispatch` only for multi-item orchestration."

const claudeWorkerPrompt = "This is a worker session. Thou art a worker in a party session, not the orchestrator. " +
	"HARD RULES: (1) Work the task before thee; do not orchestrate or spawn sub-workers. " +
	"(2) When thou hast a result for the master, report back via `party-cli report \"<result>\"` from this worker session. " +
	"(3) Worker tool cheatsheet: use `party-cli report` to reply to the master, `party-cli read <session-id>` when asked to inspect another session, " +
	"and `party-cli workers` if thou needst a quick session list for context."

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
	} else {
		systemPrompt := joinSystemPrompt(c.WorkerPrompt(), opts.SystemBrief)
		if systemPrompt != "" {
			cmd += " --append-system-prompt " + config.ShellQuote(systemPrompt)
		}
	}
	if opts.Master && opts.SystemBrief != "" {
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

func (c *Claude) ResumeKey() string      { return "claude_session_id" }
func (c *Claude) ResumeFileName() string { return "claude-session-id" }
func (c *Claude) EnvVar() string         { return "CLAUDE_SESSION_ID" }
func (c *Claude) MasterPrompt() string   { return claudeMasterPrompt }
func (c *Claude) WorkerPrompt() string   { return claudeWorkerPrompt }

func (c *Claude) FilterPaneLines(raw string, max int) []string {
	return tmux.FilterAgentLines(raw, max)
}

// IsActive reports whether Claude Code is currently producing output for
// this session. It checks the live JSONL transcript Claude appends to at
// ~/.claude/projects/<cwd-slug>/<session-uuid>.jsonl.
func (c *Claude) IsActive(cwd, resumeID string) (bool, error) {
	if resumeID == "" || cwd == "" {
		return false, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return false, fmt.Errorf("user home: %w", err)
	}
	path := filepath.Join(home, ".claude", "projects", claudeProjectSlug(cwd), resumeID+".jsonl")
	return transcriptActive(path)
}

// claudeProjectSlug mirrors Claude Code's own project-directory naming:
// every non-alphanumeric character in the absolute cwd becomes "-". That
// includes "/", ".", "_", " " and anything else, so cwds like
// /home/user/my.project or /Users/alice/code/ai_party resolve to the
// right subdirectory under ~/.claude/projects/.
func claudeProjectSlug(cwd string) string {
	var b strings.Builder
	b.Grow(len(cwd))
	for _, r := range cwd {
		switch {
		case r >= 'A' && r <= 'Z', r >= 'a' && r <= 'z', r >= '0' && r <= '9':
			b.WriteRune(r)
		default:
			b.WriteByte('-')
		}
	}
	return b.String()
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
