package session

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/alexivison/questmaster/internal/agent"
	"github.com/alexivison/questmaster/internal/repo"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
)

// StartOpts configures a new session launch.
//
// Prompt is the initial user-turn message (Claude `-- <prompt>`, Codex
// positional). SystemBrief is a rare standalone/worker system override that
// is appended after the built-in standalone or worker system prompt.
type StartOpts struct {
	Title    string
	Cwd      string
	Master   bool
	MasterID string // parent master session ID (for worker spawn)
	// DisplayColor is the named display color persisted with session metadata.
	DisplayColor string
	// ResumeIDs maps agent name → resume ID (e.g. {"claude": "abc", "codex": "xyz"}).
	ResumeIDs   map[string]string
	Prompt      string
	SystemBrief string
	QuestID     string
	Detached    bool
	FromApp     bool
}

// StartResult holds the outcome of a Start operation.
type StartResult struct {
	SessionID  string
	RuntimeDir string
	Cwd        string
}

// Start creates and launches a new questmaster session.
func (s *Service) Start(ctx context.Context, opts StartOpts) (StartResult, error) {
	cwd := opts.Cwd
	if cwd == "" {
		var err error
		cwd, err = os.Getwd()
		if err != nil {
			return StartResult{}, fmt.Errorf("get working directory: %w", err)
		}
	}

	// An explicit title is kept verbatim and locked so the first-turn hook
	// never overwrites it. A blank title is derived from the initial prompt
	// when one is given, finally honoring the picker's "auto-generated if
	// blank" promise; otherwise it stays blank for the first-turn hook to
	// fill in once the user's first message arrives.
	titleLocked := strings.TrimSpace(opts.Title) != ""
	if !titleLocked && opts.Prompt != "" {
		opts.Title = TitleFromPrompt(opts.Prompt)
	}

	role := roleStandalone
	if opts.Master {
		role = roleMaster
	} else if opts.MasterID != "" {
		role = roleWorker
	}
	agentRole := agentSessionRole(role)
	winName := windowName(opts.Title, role)
	agentPath := defaultAgentPath()

	registry, err := s.agentRegistry()
	if err != nil {
		return StartResult{}, fmt.Errorf("load agent registry: %w", err)
	}

	bindings := registry.Bindings()
	if len(bindings) == 0 {
		return StartResult{}, fmt.Errorf("resolve session roles: primary role is not configured")
	}

	resolvedAgentCLIs := make(map[agent.Role]string, len(bindings))
	for _, binding := range bindings {
		cli, resolvedPath, ok := resolveAgentBinary(binding.Agent, agentPath)
		if !ok {
			return StartResult{}, agentBinaryNotFoundError(binding.Agent)
		}
		agentPath = resolvedPath
		resolvedAgentCLIs[binding.Role] = cli
	}

	agentCmds := make(map[agent.Role]string, len(bindings))
	launchAgents := make(map[agent.Role]agent.Agent, len(bindings))
	agentResume := make(map[agent.Role]resumeInfo, len(bindings))
	manifestAgents := make([]state.AgentManifest, 0, len(bindings))
	resumeMap := opts.ResumeIDs

	for _, binding := range bindings {
		provider := binding.Agent
		cli := resolvedAgentCLIs[binding.Role]
		resumeID := resumeMap[provider.Name()]
		prompt := ""
		brief := ""
		if binding.Role == agent.RolePrimary {
			prompt = opts.Prompt
			brief = opts.SystemBrief
		}
		launchAgents[binding.Role] = provider
		agentCmds[binding.Role] = provider.BuildCmd(agent.CmdOpts{
			Binary:      cli,
			AgentPath:   agentPath,
			ResumeID:    resumeID,
			Prompt:      prompt,
			SystemBrief: brief,
			Title:       opts.Title,
			Role:        agentRole,
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

	for i := range manifestAgents {
		manifestAgents[i].Window = agentWindow(agent.Role(manifestAgents[i].Role))
	}

	// Atomic create-or-retry: claim an ID via Store.Create (flock-protected).
	// This eliminates the TOCTOU race between HasSession and NewSession.
	m := state.Manifest{
		Title:      opts.Title,
		Cwd:        cwd,
		WindowName: winName,
		Agents:     manifestAgents,
		AgentPath:  agentPath,
		Display:    s.startDisplayMetadata(opts),
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

	// Seed state.json so the tracker shows "idle (started)" instead of
	// "unknown" during the brief window between spawn and the agent's
	// first SessionStart hook. Best-effort: a failure here only loses the
	// pre-fill, not the session itself.
	seed := make(map[string]string, len(manifestAgents))
	for _, am := range manifestAgents {
		if am.Role == "" || am.Name == "" {
			continue
		}
		seed[am.Role] = am.Name
	}
	if err := state.InitStartingState(sessionID, seed); err != nil {
		fmt.Fprintf(os.Stderr, "questmaster: warning: seed initial state for %s: %v\n", sessionID, err)
	}

	if err := s.Store.Update(sessionID, func(m *state.Manifest) {
		m.SetExtra("last_started_at", state.NowUTC())
		if titleLocked {
			m.SetExtra("title_locked", "1")
		}
		if p := opts.Prompt; p != "" {
			m.SetExtra("initial_prompt", p)
		} else if p := opts.SystemBrief; p != "" {
			m.SetExtra("initial_prompt", p)
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

	if err := s.seedRepoDisplayColor(cwd, opts.DisplayColor); err != nil {
		return StartResult{}, err
	}

	if opts.MasterID != "" {
		if err := s.Store.AddWorker(opts.MasterID, sessionID); err != nil {
			return StartResult{}, fmt.Errorf("register worker: %w", err)
		}
	}

	if err := s.Client.NewSession(ctx, sessionID, winName, cwd); err != nil {
		return StartResult{}, s.startRollbackError(ctx, sessionID, fmt.Errorf("create tmux session: %w", err))
	}

	if err := s.launchSession(ctx, launchConfig{
		sessionID:   sessionID,
		cwd:         cwd,
		runtimeDir:  runtimeDir,
		title:       opts.Title,
		agentPath:   agentPath,
		master:      opts.Master,
		worker:      opts.MasterID != "",
		fromApp:     opts.FromApp,
		agentCmds:   agentCmds,
		agents:      launchAgents,
		agentResume: agentResume,
	}); err != nil {
		return StartResult{}, s.startRollbackError(ctx, sessionID, err)
	}

	return StartResult{SessionID: sessionID, RuntimeDir: runtimeDir, Cwd: cwd}, nil
}

func (s *Service) startRollbackError(ctx context.Context, sessionID string, cause error) error {
	if rollbackErr := s.rollbackStartedSession(ctx, sessionID); rollbackErr != nil {
		return fmt.Errorf("%w (rollback failed: %v)", cause, rollbackErr)
	}
	return cause
}

func (s *Service) rollbackStartedSession(ctx context.Context, sessionID string) error {
	var errs []error
	if s.Client != nil {
		if err := s.Client.KillSession(ctx, sessionID); err != nil {
			errs = append(errs, fmt.Errorf("kill partial tmux session: %w", err))
		}
	}
	if err := s.cleanupStartedSession(sessionID); err != nil {
		errs = append(errs, err)
	}
	return errors.Join(errs...)
}

func (s *Service) startDisplayMetadata(opts StartOpts) *state.DisplayMetadata {
	color := strings.TrimSpace(opts.DisplayColor)
	if color == "" && opts.MasterID != "" {
		if master, err := s.Store.Read(opts.MasterID); err == nil {
			color = master.DisplayColor()
		}
	}
	if strings.TrimSpace(color) == "" {
		return nil
	}
	return state.NewDisplayMetadata(color)
}

func (s *Service) seedRepoDisplayColor(cwd, color string) error {
	color = strings.TrimSpace(color)
	if color == "" {
		return nil
	}
	r, ok := repo.Resolve(cwd)
	if !ok {
		return nil
	}
	if err := state.NewRepoColorStore(s.Store.Root()).Set(r.Identity, color); err != nil {
		return fmt.Errorf("set repo color: %w", err)
	}
	return nil
}

// claimSessionID generates a unique session ID and atomically creates its
// manifest via Store.Create (flock-protected). Also rejects IDs that already
// exist as tmux sessions (orphan sessions without manifests). The template's
// SessionID field is overwritten with each candidate qm-* ID.
func (s *Service) claimSessionID(ctx context.Context, template state.Manifest) (string, error) {
	const maxAttempts = 100
	timestamp := s.Now()
	for attempt := range maxAttempts {
		id := state.NewSessionID(timestamp)
		if attempt > 0 {
			id = state.NewSessionIDWithSuffix(timestamp, s.RandSuffix())
		}

		template.SessionID = id
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

// persistResumeIDs writes resume IDs to the runtime directory.
func (s *Service) persistResumeIDs(rtDir string, resume map[agent.Role]resumeInfo) error {
	for _, role := range []agent.Role{agent.RolePrimary} {
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
	for _, role := range []agent.Role{agent.RolePrimary} {
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

func agentWindow(_ agent.Role) int {
	return tmux.WindowWorkspace
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
	// JSON state.
	var parentID string
	if m, err := s.Store.Read(sessionID); err == nil {
		parentID = m.ExtraString("parent_session")
	}

	if err := writeCleanupScript(scriptPath, s.Store.Root(), sessionID, parentID); err != nil {
		return fmt.Errorf("write cleanup script: %w", err)
	}

	// Tmux may run a session-scoped session-closed hook from a different
	// still-live session. Always clean the session that actually closed.
	// No $VAR references survive to tmux.
	hookCmd := `run-shell "test -x /tmp/#{q:hook_session_name}/cleanup.sh && /tmp/#{q:hook_session_name}/cleanup.sh #{q:hook_session_name}"`
	return s.Client.SetHook(ctx, sessionID, "session-closed", hookCmd)
}

// writeCleanupScript writes the session cleanup logic to a shell script.
// Paths are injected via heredoc-style quoting so spaces and special
// characters (including apostrophes) are safe. The parent session ID is
// embedded at generation time so the script doesn't need jq to discover it.
// jq is only used (best-effort) for rewriting JSON state.
func writeCleanupScript(path, stateRoot, sessionID, parentID string) error {
	// Perl is used as a portable flock wrapper (macOS ships with Perl;
	// flock CLI does not exist). system() (not exec) holds the lock
	// while bash runs the jq rewrites.
	hookStateRoot := state.StateRoot()
	script := fmt.Sprintf(`#!/bin/sh
SR=%s
HSR=%s
W=%s
p=%s
closed=${1:-}
export SR HSR W
if [ "$closed" != "$W" ]; then
  exit 0
fi
# Best-effort: persist Pi's real session UUID before removing the runtime dir.
activity="$HSR/$W/state.json"
if [ -n "$HSR" ] && [ -f "$activity" ] && [ -f "$SR/$W.json" ] && command -v jq >/dev/null 2>&1; then
  sf=$(jq -r 'select(.version == 1) | (.panes.primary.pi_session_id // .panes.primary.session_file // empty)' "$activity" 2>/dev/null || true)
  base=${sf##*/}
  pi_session_id=
  case "$base" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[0-9][0-9][0-9]Z_????????-????-????-????-????????????.jsonl)
      pi_session_id=${base#*_}
      pi_session_id=${pi_session_id%%.jsonl}
      ;;
    ????????-????-????-????-????????????)
      pi_session_id=$base
      ;;
  esac
  case "$pi_session_id" in
    ????????-????-????-????-????????????) ;;
    *) pi_session_id= ;;
  esac
  case "$pi_session_id" in
    *[!A-Za-z0-9_-]*) pi_session_id= ;;
  esac
  if [ -n "$pi_session_id" ] && ! printf '%%s\n' "$pi_session_id" | grep -Eq '^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$'; then
    pi_session_id=
  fi
  if [ -n "$pi_session_id" ]; then
    export pi_session_id
    perl -MFcntl=:flock -e \
      'open my $f,">",shift or exit 1;flock($f,LOCK_EX) or exit 1;exit(system(@ARGV)>>8)' \
      "$SR/$W.json.lock" \
      bash -c 'tmp=$(mktemp)
        jq --arg v "$pi_session_id" '"'"'.pi_session_id = $v | if (.agents | type) == "array" then .agents = (.agents | map(if .name == "pi" then .resume_id = $v else . end)) else . end'"'"' "$SR/$W.json" >"$tmp" \
          && mv "$tmp" "$SR/$W.json" \
          || rm -f "$tmp"'
  fi
fi
# Best-effort: remove this worker from parent's worker list (requires jq).
if [ -n "$p" ] && [ -f "$SR/$p.json" ] && command -v jq >/dev/null 2>&1; then
  export p
  perl -MFcntl=:flock -e \
    'open my $f,">",shift or exit 1;flock($f,LOCK_EX) or exit 1;exit(system(@ARGV)>>8)' \
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
`, shellQuoteForScript(stateRoot), shellQuoteForScript(hookStateRoot), shellQuoteForScript(sessionID), shellQuoteForScript(parentID))

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
