package session

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/anthropics/ai-party/tools/party-cli/internal/agent"
	"github.com/anthropics/ai-party/tools/party-cli/internal/state"
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

const workerReportContract = "\n\nThis is a worker session. When thou hast a result for the master, report back via `party-cli report \"<result>\"`.\n" +
	"For small deliverables, include the actual answer in the report. For larger tasks, send a one-line summary and keep supporting detail in this pane."

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

	role := roleStandalone
	if opts.Master {
		role = roleMaster
	} else if opts.MasterID != "" {
		role = roleWorker
	}
	winName := windowName(opts.Title, role)
	agentPath := defaultAgentPath()
	layout := opts.Layout
	if layout == "" {
		layout = resolveLayout()
	}

	registry, err := s.agentRegistry()
	if err != nil {
		return StartResult{}, fmt.Errorf("load agent registry: %w", err)
	}

	bindings, err := sessionBindings(registry, opts.Master)
	if err != nil {
		return StartResult{}, fmt.Errorf("resolve session roles: %w", err)
	}

	agentCmds := make(map[agent.Role]string, len(bindings))
	launchAgents := make(map[agent.Role]agent.Agent, len(bindings))
	agentResume := make(map[agent.Role]resumeInfo, len(bindings))
	manifestAgents := make([]state.AgentManifest, 0, len(bindings))
	resumeMap := legacyResumeMap(opts.ClaudeResumeID, opts.CodexResumeID)

	initialPrompt := opts.Prompt
	if opts.MasterID != "" {
		initialPrompt = augmentWorkerPrompt(opts.Prompt)
	}

	for _, binding := range bindings {
		provider := binding.Agent
		cli, ok := resolveAgentBinary(provider)
		if !ok {
			if binding.Role == agent.RoleCompanion {
				fmt.Fprintf(os.Stderr, "party-cli: warning: skipping %s companion; binary not found (%s)\n", provider.Name(), cli)
				continue
			}
			return StartResult{}, fmt.Errorf("resolve %s binary: not found", provider.Name())
		}

		resumeID := resumeMap[provider.Name()]
		prompt := ""
		if binding.Role == agent.RolePrimary {
			prompt = initialPrompt
		}
		launchAgents[binding.Role] = provider
		agentCmds[binding.Role] = provider.BuildCmd(agent.CmdOpts{
			Binary:    cli,
			AgentPath: agentPath,
			ResumeID:  resumeID,
			Prompt:    prompt,
			Title:     opts.Title,
			Master:    opts.Master && binding.Role == agent.RolePrimary,
		})
		if resumeID != "" {
			agentResume[binding.Role] = resumeInfo{
				provider: provider,
				resumeID: resumeID,
			}
		}
		manifestAgents = append(manifestAgents, state.AgentManifest{
			Name:     provider.Name(),
			Role:     string(binding.Role),
			CLI:      cli,
			ResumeID: resumeID,
		})
	}

	hasCompanion := agentCmds[agent.RoleCompanion] != ""
	for i := range manifestAgents {
		manifestAgents[i].Window = agentWindow(layout, opts.Master, agent.Role(manifestAgents[i].Role), hasCompanion)
	}

	// Atomic create-or-retry: claim an ID via Store.Create (flock-protected).
	// This eliminates the TOCTOU race between HasSession and NewSession.
	m := state.Manifest{
		Title:      opts.Title,
		Cwd:        cwd,
		WindowName: winName,
		Agents:     manifestAgents,
		AgentPath:  agentPath,
	}
	if opts.Master {
		m.SessionType = "master"
	}
	sessionID, err := s.claimSessionID(ctx, m)
	if err != nil {
		return StartResult{}, err
	}

	runtimeDir, err := ensureRuntimeDir(sessionID)
	if err != nil {
		_ = s.Store.Delete(sessionID) // rollback manifest
		return StartResult{}, err
	}

	if err := s.Store.Update(sessionID, func(m *state.Manifest) {
		m.SetExtra("last_started_at", state.NowUTC())
		if opts.Prompt != "" {
			m.SetExtra("initial_prompt", opts.Prompt)
		}
		for _, binding := range bindings {
			resumeID := resumeMap[binding.Agent.Name()]
			if resumeID == "" {
				continue
			}
			m.SetExtra(binding.Agent.ResumeKey(), resumeID)
		}
		if opts.MasterID != "" {
			m.SetExtra("parent_session", opts.MasterID)
		}
	}); err != nil {
		return StartResult{}, fmt.Errorf("update manifest: %w", err)
	}

	if opts.MasterID != "" {
		if err := s.Store.AddWorker(opts.MasterID, sessionID); err != nil {
			return StartResult{}, fmt.Errorf("register worker: %w", err)
		}
	}

	if err := s.Client.NewSession(ctx, sessionID, winName, cwd); err != nil {
		return StartResult{}, fmt.Errorf("create tmux session: %w", err)
	}

	if err := s.launchSession(ctx, launchConfig{
		sessionID:   sessionID,
		cwd:         cwd,
		runtimeDir:  runtimeDir,
		title:       opts.Title,
		agentPath:   agentPath,
		prompt:      opts.Prompt,
		master:      opts.Master,
		worker:      opts.MasterID != "",
		layout:      layout,
		agentCmds:   agentCmds,
		agents:      launchAgents,
		agentResume: agentResume,
	}); err != nil {
		return StartResult{}, err
	}

	return StartResult{SessionID: sessionID, RuntimeDir: runtimeDir}, nil
}

func augmentWorkerPrompt(prompt string) string {
	if prompt == "" {
		return strings.TrimSpace(workerReportContract)
	}
	if strings.Contains(prompt, "party-cli report") || strings.Contains(prompt, "party-relay.sh --report") {
		return prompt
	}
	return prompt + workerReportContract
}

// claimSessionID generates a unique session ID and atomically creates its
// manifest via Store.Create (flock-protected). Also rejects IDs that already
// exist as tmux sessions (orphan sessions without manifests). The template's
// PartyID is overwritten with each candidate ID.
func (s *Service) claimSessionID(ctx context.Context, template state.Manifest) (string, error) {
	const maxAttempts = 100
	for attempt := range maxAttempts {
		var id string
		if attempt == 0 {
			id = fmt.Sprintf("party-%d", s.Now())
		} else {
			id = fmt.Sprintf("party-%d-%d", s.Now(), s.RandSuffix())
		}

		template.PartyID = id
		if err := s.Store.Create(template); err != nil {
			if errors.Is(err, state.ErrManifestExists) {
				continue
			}
			return "", fmt.Errorf("create manifest: %w", err)
		}

		// Guard against orphan tmux sessions that have no manifest.
		// Propagate real transport errors; benign "no server" returns (false, nil).
		exists, hsErr := s.Client.HasSession(ctx, id)
		if hsErr != nil {
			if delErr := s.Store.Delete(id); delErr != nil && !isManifestNotFound(delErr) {
				return "", fmt.Errorf("check tmux session %s: %w (rollback failed: %v)", id, hsErr, delErr)
			}
			return "", fmt.Errorf("check tmux session %s: %w", id, hsErr)
		}
		if exists {
			_ = s.Store.Delete(id) // best-effort; retries use different IDs
			continue
		}

		return id, nil
	}
	return "", fmt.Errorf("failed to generate unique session ID after %d attempts", maxAttempts)
}

// resolveBinary finds a binary by env var, PATH, or default.
func resolveBinary(envKey, name, fallback string) string {
	if v := os.Getenv(envKey); v != "" {
		return v
	}
	if p, err := exec.LookPath(name); err == nil {
		return p
	}
	return expandUserPath(fallback)
}

// resolveLayout reads PARTY_LAYOUT from the environment.
// Default is sidebar; set PARTY_LAYOUT=classic to use the legacy layout.
func resolveLayout() LayoutMode {
	if v := os.Getenv("PARTY_LAYOUT"); v == "classic" {
		return LayoutClassic
	}
	return LayoutSidebar
}

// persistResumeIDs writes resume IDs to the runtime directory.
func (s *Service) persistResumeIDs(rtDir string, resume map[agent.Role]resumeInfo) error {
	for _, role := range []agent.Role{agent.RolePrimary, agent.RoleCompanion} {
		info, ok := resume[role]
		if !ok || info.resumeID == "" || info.provider == nil {
			continue
		}
		path := filepath.Join(rtDir, info.provider.ResumeFileName())
		if err := os.WriteFile(path, []byte(info.resumeID+"\n"), 0o644); err != nil {
			return fmt.Errorf("write %s: %w", info.provider.ResumeFileName(), err)
		}
	}
	return nil
}

// setResumeEnv sets resume ID env vars in the tmux session.
func (s *Service) setResumeEnv(ctx context.Context, sessionID string, resume map[agent.Role]resumeInfo) error {
	for _, role := range []agent.Role{agent.RolePrimary, agent.RoleCompanion} {
		info, ok := resume[role]
		if !ok || info.resumeID == "" || info.provider == nil {
			continue
		}
		if err := s.Client.SetEnvironment(ctx, sessionID, info.provider.EnvVar(), info.resumeID); err != nil {
			return err
		}
	}
	return nil
}

func defaultAgentPath() string {
	return fmt.Sprintf("%s/.local/bin:/opt/homebrew/bin:%s", os.Getenv("HOME"), os.Getenv("PATH"))
}

func legacyResumeMap(claudeResumeID, codexResumeID string) map[string]string {
	resume := map[string]string{}
	if claudeResumeID != "" {
		resume["claude"] = claudeResumeID
	}
	if codexResumeID != "" {
		resume["codex"] = codexResumeID
	}
	return resume
}

func resolveAgentBinary(provider agent.Agent) (string, bool) {
	if v := os.Getenv(provider.BinaryEnvVar()); v != "" {
		return v, true
	}
	if p, err := exec.LookPath(provider.Binary()); err == nil {
		return p, true
	}
	fallback := expandUserPath(provider.FallbackPath())
	if fallback == "" {
		return "", false
	}
	if _, err := os.Stat(fallback); err == nil {
		return fallback, true
	}
	return fallback, false
}

func sessionBindings(registry *agent.Registry, master bool) ([]*agent.RoleBinding, error) {
	if !master {
		return registry.Bindings(), nil
	}
	binding, err := registry.ForRole(agent.RolePrimary)
	if err != nil {
		return nil, err
	}
	return []*agent.RoleBinding{binding}, nil
}

func agentWindow(layout LayoutMode, master bool, role agent.Role, hasCompanion bool) int {
	if master {
		return 0
	}
	if layout == LayoutSidebar && role == agent.RolePrimary && hasCompanion {
		return 1
	}
	return 0
}

func expandUserPath(path string) string {
	if path == "" || path[0] != '~' {
		return path
	}
	home := os.Getenv("HOME")
	switch {
	case path == "~":
		return home
	case strings.HasPrefix(path, "~/"):
		return filepath.Join(home, path[2:])
	default:
		return path
	}
}

// setCleanupHook registers the session-closed hook for cleanup.
// On session close: deregister from parent's workers list (via jq),
// remove runtime dir, then delete manifest unless it's a master.
//
// CRITICAL: tmux's run-shell expands $NAME patterns using its own format
// system BEFORE passing the command to the shell. Unescaped $VAR references
// expand to empty, turning "rm -rf /tmp/$W" into "rm -rf /tmp/" which
// deletes the tmux socket and kills the server.
//
// To avoid both tmux format expansion AND shell quoting issues with paths
// containing spaces or special characters, the cleanup logic is written to
// a script file in the runtime dir. The hook simply calls that script.
func (s *Service) setCleanupHook(ctx context.Context, sessionID string) error {
	runtimeDir := runtimeDir(sessionID)
	scriptPath := filepath.Join(runtimeDir, "cleanup.sh")

	// Embed parent ID at hook-creation time so the cleanup script doesn't
	// need jq to discover it. jq is only used (best-effort) for rewriting
	// the parent's worker list.
	var parentID string
	if m, err := s.Store.Read(sessionID); err == nil {
		parentID = m.ExtraString("parent_session")
	}

	if err := writeCleanupScript(scriptPath, s.Store.Root(), sessionID, parentID); err != nil {
		return fmt.Errorf("write cleanup script: %w", err)
	}

	// The hook just calls the script. No $VAR references survive to tmux.
	hookCmd := fmt.Sprintf(`run-shell "%s"`, scriptPath)
	return s.Client.SetHook(ctx, sessionID, "session-closed", hookCmd)
}

// writeCleanupScript writes the session cleanup logic to a shell script.
// Paths are injected via heredoc-style quoting so spaces and special
// characters (including apostrophes) are safe. The parent session ID is
// embedded at generation time so the script doesn't need jq to discover it.
// jq is only used (best-effort) for rewriting the parent's worker list.
func writeCleanupScript(path, stateRoot, sessionID, parentID string) error {
	// Perl is used as a portable flock wrapper (macOS ships with Perl;
	// flock CLI does not exist). system() (not exec) holds the lock
	// while bash runs the jq rewrite.
	script := fmt.Sprintf(`#!/bin/sh
export SR=%s
W=%s
p=%s
# Best-effort: remove this worker from parent's worker list (requires jq).
if [ -n "$p" ] && [ -f "$SR/$p.json" ] && command -v jq >/dev/null 2>&1; then
  export p
  perl -MFcntl=:flock -e \
    'open my $f,">",shift or exit 1;flock($f,LOCK_EX) or exit 1;exit(system(@ARGV[1..$#ARGV])>>8)' \
    "$SR/$p.json.lock" \
    bash -c 'tmp=$(mktemp)
      jq --arg w "'"$W"'" '"'"'.workers=((.workers//[])-[$w])'"'"' "$SR/$p.json" >"$tmp" \
        && mv "$tmp" "$SR/$p.json" \
        || rm -f "$tmp"'
fi
rm -rf "/tmp/$W"
# Manifests are NOT deleted on session close — the prune command handles
# stale manifest cleanup with proper parent deregistration (7-day TTL).
# Deleting here causes the picker to misclassify workers as standalone.
exit 0
`, shellQuoteForScript(stateRoot), shellQuoteForScript(sessionID), shellQuoteForScript(parentID))

	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, []byte(script), 0o755)
}

// shellQuoteForScript wraps a value in single quotes for safe embedding in
// a shell script, escaping any embedded single quotes.
func shellQuoteForScript(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'"'"'`) + "'"
}
