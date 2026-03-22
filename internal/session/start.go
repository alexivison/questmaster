package session

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/anthropics/ai-config/tools/party-cli/internal/config"
	"github.com/anthropics/ai-config/tools/party-cli/internal/state"
)

// StartOpts configures a new session launch.
type StartOpts struct {
	Title          string
	Cwd            string
	Layout         LayoutMode
	Master         bool
	MasterID       string // parent master session ID (for worker spawn)
	ClaudeResumeID string
	CodexResumeID  string
	Prompt         string
	Detached       bool
}

// StartResult holds the outcome of a Start operation.
type StartResult struct {
	SessionID  string
	RuntimeDir string
}

// Start creates and launches a new party session.
func (s *Service) Start(ctx context.Context, opts StartOpts) (StartResult, error) {
	cwd := opts.Cwd
	if cwd == "" {
		var err error
		cwd, err = os.Getwd()
		if err != nil {
			return StartResult{}, fmt.Errorf("get working directory: %w", err)
		}
	}

	sessionID, err := s.generateSessionID(ctx)
	if err != nil {
		return StartResult{}, err
	}

	winName := windowName(opts.Title)
	claudeBin := resolveBinary("CLAUDE_BIN", "claude", filepath.Join(os.Getenv("HOME"), ".local", "bin", "claude"))
	codexBin := resolveBinary("CODEX_BIN", "codex", "/opt/homebrew/bin/codex")
	agentPath := fmt.Sprintf("%s/.local/bin:/opt/homebrew/bin:%s", os.Getenv("HOME"), os.Getenv("PATH"))

	runtimeDir, err := ensureRuntimeDir(sessionID)
	if err != nil {
		return StartResult{}, err
	}

	m := state.Manifest{
		PartyID:    sessionID,
		Title:      opts.Title,
		Cwd:        cwd,
		WindowName: winName,
		ClaudeBin:  claudeBin,
		CodexBin:   codexBin,
		AgentPath:  agentPath,
	}
	if opts.Master {
		m.SessionType = "master"
	}
	if err := s.Store.Create(m); err != nil {
		return StartResult{}, fmt.Errorf("create manifest: %w", err)
	}

	if err := s.Store.Update(sessionID, func(m *state.Manifest) {
		setExtraField(m, "last_started_at", nowUTC())
		if opts.Prompt != "" {
			setExtraField(m, "initial_prompt", opts.Prompt)
		}
		if opts.ClaudeResumeID != "" {
			setExtraField(m, "claude_session_id", opts.ClaudeResumeID)
		}
		if opts.CodexResumeID != "" {
			setExtraField(m, "codex_thread_id", opts.CodexResumeID)
		}
	}); err != nil {
		return StartResult{}, fmt.Errorf("update manifest: %w", err)
	}

	if opts.MasterID != "" {
		if err := s.Store.Update(sessionID, func(m *state.Manifest) {
			setExtraField(m, "parent_session", opts.MasterID)
		}); err != nil {
			return StartResult{}, fmt.Errorf("set parent: %w", err)
		}
		if err := s.Store.AddWorker(opts.MasterID, sessionID); err != nil {
			return StartResult{}, fmt.Errorf("register worker: %w", err)
		}
	}

	if err := s.Client.NewSession(ctx, sessionID, winName, cwd); err != nil {
		return StartResult{}, fmt.Errorf("create tmux session: %w", err)
	}

	if err := s.clearClaudeCodeEnv(ctx, sessionID); err != nil {
		return StartResult{}, err
	}

	if opts.Master {
		claudeCmd := buildClaudeCmd(claudeBin, agentPath, opts.ClaudeResumeID, opts.Prompt, opts.Title)
		if err := s.persistResumeIDs(sessionID, runtimeDir, opts.ClaudeResumeID, ""); err != nil {
			return StartResult{}, err
		}
		if err := s.setResumeEnv(ctx, sessionID, opts.ClaudeResumeID, ""); err != nil {
			return StartResult{}, err
		}
		if err := s.launchMaster(ctx, sessionID, cwd, claudeCmd); err != nil {
			return StartResult{}, err
		}
	} else {
		layout := opts.Layout
		if layout == "" {
			layout = resolveLayout()
		}
		if err := s.Client.SetEnvironment(ctx, sessionID, "PARTY_LAYOUT", string(layout)); err != nil {
			return StartResult{}, err
		}

		claudeCmd := buildClaudeCmd(claudeBin, agentPath, opts.ClaudeResumeID, opts.Prompt, opts.Title)
		codexCmd := buildCodexCmd(codexBin, agentPath, opts.CodexResumeID)
		if err := s.persistResumeIDs(sessionID, runtimeDir, opts.ClaudeResumeID, opts.CodexResumeID); err != nil {
			return StartResult{}, err
		}
		if err := s.setResumeEnv(ctx, sessionID, opts.ClaudeResumeID, opts.CodexResumeID); err != nil {
			return StartResult{}, err
		}

		if layout == LayoutSidebar {
			if err := s.launchSidebar(ctx, sessionID, cwd, codexCmd, claudeCmd, opts.Title); err != nil {
				return StartResult{}, err
			}
		} else {
			if err := s.launchClassic(ctx, sessionID, cwd, codexCmd, claudeCmd); err != nil {
				return StartResult{}, err
			}
		}
	}

	if err := s.setCleanupHook(ctx, sessionID); err != nil {
		return StartResult{}, err
	}

	return StartResult{SessionID: sessionID, RuntimeDir: runtimeDir}, nil
}

// generateSessionID creates a unique session ID.
func (s *Service) generateSessionID(ctx context.Context) (string, error) {
	base := fmt.Sprintf("party-%d", s.Now())
	exists, err := s.Client.HasSession(ctx, base)
	if err != nil {
		return "", fmt.Errorf("check session: %w", err)
	}
	if !exists {
		return base, nil
	}
	for range 100 {
		id := fmt.Sprintf("party-%d-%d", s.Now(), s.RandSuffix())
		exists, err := s.Client.HasSession(ctx, id)
		if err != nil {
			return "", fmt.Errorf("check session: %w", err)
		}
		if !exists {
			return id, nil
		}
	}
	return "", fmt.Errorf("failed to generate unique session ID")
}

// resolveBinary finds a binary by env var, PATH, or default.
func resolveBinary(envKey, name, fallback string) string {
	if v := os.Getenv(envKey); v != "" {
		return v
	}
	if p, err := exec.LookPath(name); err == nil {
		return p
	}
	return fallback
}

// resolveLayout reads PARTY_LAYOUT from the environment.
// Default is sidebar; set PARTY_LAYOUT=classic to use the legacy layout.
func resolveLayout() LayoutMode {
	if v := os.Getenv("PARTY_LAYOUT"); v == "classic" {
		return LayoutClassic
	}
	return LayoutSidebar
}

// buildClaudeCmd builds the shell command string for launching Claude.
func buildClaudeCmd(claudeBin, agentPath, resumeID, prompt, title string) string {
	cmd := fmt.Sprintf("export PATH=%s; unset CLAUDECODE; exec %s --dangerously-skip-permissions",
		config.ShellQuote(agentPath), config.ShellQuote(claudeBin))
	if title != "" {
		cmd += " --name " + config.ShellQuote(title)
	}
	if resumeID != "" {
		cmd += " --resume " + config.ShellQuote(resumeID)
	}
	if prompt != "" {
		cmd += " -- " + config.ShellQuote(prompt)
	}
	return cmd
}

// buildCodexCmd builds the shell command string for launching Codex.
func buildCodexCmd(codexBin, agentPath, resumeID string) string {
	cmd := fmt.Sprintf("export PATH=%s; exec %s --dangerously-bypass-approvals-and-sandbox",
		config.ShellQuote(agentPath), config.ShellQuote(codexBin))
	if resumeID != "" {
		cmd += " resume " + config.ShellQuote(resumeID)
	}
	return cmd
}

// clearClaudeCodeEnv removes the CLAUDECODE env var from tmux.
// Errors are intentionally ignored — mirrors party.sh:100-101 where the
// unset is best-effort (the var may not exist, or tmux may not be running).
func (s *Service) clearClaudeCodeEnv(ctx context.Context, sessionID string) error {
	_ = s.Client.UnsetEnvironment(ctx, "", "CLAUDECODE")
	_ = s.Client.UnsetEnvironment(ctx, sessionID, "CLAUDECODE")
	return nil
}

// persistResumeIDs writes resume IDs to the runtime directory.
func (s *Service) persistResumeIDs(sessionID, rtDir, claudeID, codexID string) error {
	if claudeID != "" {
		path := filepath.Join(rtDir, "claude-session-id")
		if err := os.WriteFile(path, []byte(claudeID+"\n"), 0o644); err != nil {
			return fmt.Errorf("write claude-session-id: %w", err)
		}
	}
	if codexID != "" {
		path := filepath.Join(rtDir, "codex-thread-id")
		if err := os.WriteFile(path, []byte(codexID+"\n"), 0o644); err != nil {
			return fmt.Errorf("write codex-thread-id: %w", err)
		}
	}
	return nil
}

// setResumeEnv sets resume ID env vars in the tmux session.
func (s *Service) setResumeEnv(ctx context.Context, sessionID, claudeID, codexID string) error {
	if claudeID != "" {
		if err := s.Client.SetEnvironment(ctx, sessionID, "CLAUDE_SESSION_ID", claudeID); err != nil {
			return err
		}
	}
	if codexID != "" {
		if err := s.Client.SetEnvironment(ctx, sessionID, "CODEX_THREAD_ID", codexID); err != nil {
			return err
		}
	}
	return nil
}

// setCleanupHook registers the session-closed hook for cleanup.
// On session close: deregister from parent's workers list (via jq),
// remove runtime dir, then delete manifest unless it's a master.
func (s *Service) setCleanupHook(ctx context.Context, sessionID string) error {
	qStateRoot := config.ShellQuote(s.Store.Root())
	// Deregister from parent via jq, coordinating with Go's flock on the
	// same .json.lock file used by state.Store. Perl is used as a portable
	// flock wrapper (macOS ships with Perl; flock CLI does not exist).
	// Use system() (not exec) so Perl holds the flock while bash runs.
	// exec() would replace the process, closing the lock fd before the rewrite.
	hookCmd := fmt.Sprintf(
		`run-shell "export SR=%s W=%s; p=$(jq -r '.parent_session // empty' $SR/$W.json 2>/dev/null); if [ -n \"$p\" ] && [ -f \"$SR/$p.json\" ]; then export p; perl -MFcntl=:flock -e 'open my $f,\">\",shift or exit 1;flock($f,LOCK_EX) or exit 1;exit(system(@ARGV[1..$#ARGV])>>8)' \"$SR/$p.json.lock\" bash -c 'tmp=$(mktemp);jq --arg w \"$W\" '\"'\"'.workers=((.workers//[])-[$w])'\"'\"' \"$SR/$p.json\" >\"$tmp\" && mv \"$tmp\" \"$SR/$p.json\" || rm -f \"$tmp\"'; fi; rm -rf /tmp/$W; t=$(jq -r '.session_type // empty' $SR/$W.json 2>/dev/null); [ \"$t\" != master ] && rm -f $SR/$W.json; true"`,
		qStateRoot,
		sessionID,
	)
	return s.Client.SetHook(ctx, sessionID, "session-closed", hookCmd)
}
