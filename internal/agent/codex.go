package agent

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"github.com/anthropics/ai-party/tools/party-cli/internal/config"
	"github.com/anthropics/ai-party/tools/party-cli/internal/tmux"
)

const codexMasterPrompt = "This is a master session. You are an orchestrator, not an implementor. " +
	"HARD RULES: (1) Never edit or write production code yourself — delegate all code changes to workers. " +
	"(2) Spawn workers with `party-cli spawn [title]` or `~/Code/ai-party/session/party-relay.sh --spawn [--prompt \"...\"] [title]`. " +
	"Relay follow-up instructions with `party-cli relay <worker-id> \"message\"`, broadcast with `party-cli broadcast \"message\"`, " +
	"and inspect workers with `party-cli workers` or the tracker pane. " +
	"(3) Read-only investigation is fine."

const codexWorkerPrompt = "This is a worker session. You are a worker in a party session, not the orchestrator. " +
	"HARD RULES: (1) Work on the task in front of you; do not orchestrate or spawn sub-workers. " +
	"(2) When you have a result for the master, report back via `party-cli report \"<result>\"` from this worker session. " +
	"(3) Worker tool cheatsheet: use `party-cli report` to reply to the master, `party-cli read <session-id>` when asked to inspect another session, " +
	"and `party-cli workers` if you need a quick session list for context."

// Codex implements the built-in Codex provider.
type Codex struct {
	cli string
}

// NewCodex constructs a Codex provider from config.
func NewCodex(cfg AgentConfig) *Codex {
	cli := cfg.CLI
	if cli == "" {
		cli = "codex"
	}
	return &Codex{cli: cli}
}

func (c *Codex) Name() string        { return "codex" }
func (c *Codex) DisplayName() string { return "The Wizard" }
func (c *Codex) Binary() string      { return c.cli }

func (c *Codex) BuildCmd(opts CmdOpts) string {
	binary := opts.Binary
	if binary == "" {
		binary = c.Binary()
	}

	cmd := fmt.Sprintf("export PATH=%s; exec %s --dangerously-bypass-approvals-and-sandbox",
		config.ShellQuote(opts.AgentPath), config.ShellQuote(binary))
	if opts.Master {
		cmd += " -c " + config.ShellQuote("developer_instructions="+strconv.Quote(c.MasterPrompt()))
	} else {
		systemPrompt := joinSystemPrompt(c.WorkerPrompt(), opts.SystemBrief)
		if systemPrompt != "" {
			cmd += " -c " + config.ShellQuote("developer_instructions="+strconv.Quote(systemPrompt))
		}
	}
	if opts.ResumeID != "" {
		cmd += " resume " + config.ShellQuote(opts.ResumeID)
	}
	if opts.Prompt != "" {
		cmd += " " + config.ShellQuote(opts.Prompt)
	}
	return cmd
}

func (c *Codex) ResumeKey() string      { return "codex_thread_id" }
func (c *Codex) ResumeFileName() string { return "codex-thread-id" }
func (c *Codex) EnvVar() string         { return "CODEX_THREAD_ID" }
func (c *Codex) MasterPrompt() string   { return codexMasterPrompt }
func (c *Codex) WorkerPrompt() string   { return codexWorkerPrompt }

func (c *Codex) FilterPaneLines(raw string, max int) []string {
	return tmux.FilterWizardLines(raw, max)
}

type codexRolloutMeta struct {
	Type      string `json:"type"`
	Timestamp string `json:"timestamp"`
	Payload   struct {
		ID        string `json:"id"`
		Cwd       string `json:"cwd"`
		Timestamp string `json:"timestamp"`
	} `json:"payload"`
}

type codexResumeCandidate struct {
	id        string
	path      string
	startedAt time.Time
	modTime   time.Time
}

// IsActive reports whether Codex is currently producing output for this
// thread. It checks the freshest rollout JSONL under
// ~/.codex/sessions/YYYY/MM/DD/ whose filename contains the thread ID.
// Rollouts are indexed by date + thread, not cwd, so cwd is ignored.
func (c *Codex) IsActive(_, resumeID string) (bool, error) {
	if resumeID == "" {
		return false, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return false, fmt.Errorf("user home: %w", err)
	}
	pattern := filepath.Join(home, ".codex", "sessions", "*", "*", "*", "rollout-*"+resumeID+".jsonl")
	matches, _ := filepath.Glob(pattern)
	if len(matches) == 0 {
		return false, nil
	}
	freshest := matches[0]
	freshestMod := statMTime(freshest)
	for _, m := range matches[1:] {
		if mt := statMTime(m); mt.After(freshestMod) {
			freshest = m
			freshestMod = mt
		}
	}
	return transcriptActive(freshest)
}

// RecoverResumeID reconstructs a fresh Codex thread ID from rollout
// metadata when the manifest is missing codex_thread_id. It uses the
// session cwd plus created_at to deterministically pick the closest
// matching rollout when several Codex sessions live in the same repo.
func (c *Codex) RecoverResumeID(cwd, createdAt string) (string, error) {
	if cwd == "" {
		return "", nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("user home: %w", err)
	}

	created := parseCodexTimestamp(createdAt)
	var best codexResumeCandidate
	found := false
	for _, path := range recentCodexRollouts(home, time.Now()) {
		meta, err := readCodexRolloutMeta(path)
		if err != nil || meta.Type != "session_meta" {
			continue
		}
		if meta.Payload.ID == "" || meta.Payload.Cwd != cwd {
			continue
		}

		candidate := codexResumeCandidate{
			id:        meta.Payload.ID,
			path:      path,
			startedAt: parseCodexTimestamp(meta.Payload.Timestamp),
			modTime:   statMTime(path),
		}
		if !found || codexCandidateBetter(candidate, best, created) {
			best = candidate
			found = true
		}
	}
	if !found {
		return "", nil
	}
	return best.id, nil
}

// statMTime returns a file's modification time, or the zero time when
// the file cannot be stat'd.
//
// TODO(dedup): state/discovery.go has a near-identical fileModTime.
// Move both into an internal/fsutil package (or export one) once we
// have a third caller — not worth a new package for two.
func statMTime(path string) (t time.Time) {
	info, err := os.Stat(path)
	if err != nil {
		return t
	}
	return info.ModTime()
}

func (c *Codex) PreLaunchSetup(_ context.Context, _ TmuxClient, _ string) error {
	return nil
}

func (c *Codex) BinaryEnvVar() string { return "CODEX_BIN" }
func (c *Codex) FallbackPath() string { return "/opt/homebrew/bin/codex" }

func readCodexRolloutMeta(path string) (codexRolloutMeta, error) {
	f, err := os.Open(path)
	if err != nil {
		return codexRolloutMeta{}, err
	}
	defer f.Close()

	line, err := bufio.NewReader(f).ReadBytes('\n')
	if err != nil && len(line) == 0 {
		return codexRolloutMeta{}, err
	}

	var meta codexRolloutMeta
	if err := json.Unmarshal(line, &meta); err != nil {
		return codexRolloutMeta{}, err
	}
	return meta, nil
}

func recentCodexRollouts(home string, now time.Time) []string {
	seen := make(map[string]struct{}, 2)
	out := make([]string, 0, 16)
	for _, day := range []time.Time{now, now.AddDate(0, 0, -1)} {
		dir := filepath.Join(home, ".codex", "sessions", day.Format("2006"), day.Format("01"), day.Format("02"))
		if _, ok := seen[dir]; ok {
			continue
		}
		seen[dir] = struct{}{}
		matches, _ := filepath.Glob(filepath.Join(dir, "rollout-*.jsonl"))
		out = append(out, matches...)
	}
	return out
}

func parseCodexTimestamp(raw string) time.Time {
	if raw == "" {
		return time.Time{}
	}
	for _, layout := range []string{time.RFC3339Nano, time.RFC3339} {
		if parsed, err := time.Parse(layout, raw); err == nil {
			return parsed
		}
	}
	return time.Time{}
}

func codexCandidateBetter(candidate, current codexResumeCandidate, createdAt time.Time) bool {
	if !createdAt.IsZero() {
		candidateDiff := codexAbsDuration(candidate.startedAt.Sub(createdAt))
		currentDiff := codexAbsDuration(current.startedAt.Sub(createdAt))
		switch {
		case candidateDiff < currentDiff:
			return true
		case candidateDiff > currentDiff:
			return false
		}
	}
	if !candidate.modTime.Equal(current.modTime) {
		return candidate.modTime.After(current.modTime)
	}
	return candidate.path > current.path
}

func codexAbsDuration(d time.Duration) time.Duration {
	if d < 0 {
		return -d
	}
	return d
}
