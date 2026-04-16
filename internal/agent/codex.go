package agent

import (
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

const codexStaleThreshold = 30 * time.Minute

const codexMasterPrompt = "This is a master session. You are an orchestrator, not an implementor. " +
	"HARD RULES: (1) Never edit or write production code yourself — delegate all code changes to workers. " +
	"(2) Spawn workers with `party-cli spawn [title]` or `~/Code/ai-party/session/party-relay.sh --spawn [--prompt \"...\"] [title]`. " +
	"Relay follow-up instructions with `party-cli relay <worker-id> \"message\"`, broadcast with `party-cli broadcast \"message\"`, " +
	"and inspect workers with `party-cli workers` or the tracker pane. " +
	"(3) Read-only investigation is fine."

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
func (c *Codex) StateFileName() string  { return "codex-status.json" }

func (c *Codex) ReadState(runtimeDir string) (AgentState, error) {
	path := filepath.Join(runtimeDir, c.StateFileName())
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return AgentState{State: "offline"}, nil
		}
		return AgentState{}, fmt.Errorf("read codex status: %w", err)
	}
	if len(data) == 0 {
		return AgentState{State: "offline"}, nil
	}

	var payload struct {
		State      string `json:"state"`
		Target     string `json:"target,omitempty"`
		Mode       string `json:"mode,omitempty"`
		Verdict    string `json:"verdict,omitempty"`
		StartedAt  string `json:"started_at,omitempty"`
		FinishedAt string `json:"finished_at,omitempty"`
		Error      string `json:"error,omitempty"`
	}
	if err := json.Unmarshal(data, &payload); err != nil || payload.State == "" {
		return AgentState{State: "offline"}, nil
	}

	state := AgentState{
		State:   payload.State,
		Mode:    payload.Mode,
		Target:  payload.Target,
		Verdict: payload.Verdict,
		Error:   payload.Error,
	}

	if payload.State == "working" && payload.StartedAt != "" {
		started, parseErr := time.Parse(time.RFC3339, payload.StartedAt)
		if parseErr == nil && time.Since(started) > codexStaleThreshold {
			state.State = "error"
			state.Error = "stale: started " + payload.StartedAt
		}
	}

	return state, nil
}

func (c *Codex) FilterPaneLines(raw string, max int) []string {
	return tmux.FilterWizardLines(raw, max)
}

func (c *Codex) PreLaunchSetup(_ context.Context, _ TmuxClient, _ string) error {
	return nil
}

func (c *Codex) BinaryEnvVar() string { return "CODEX_BIN" }
func (c *Codex) FallbackPath() string { return "/opt/homebrew/bin/codex" }
