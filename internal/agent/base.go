package agent

import (
	"context"

	"github.com/alexivison/questmaster/internal/tmux"
)

// paneFilter selects which tmux line filter a provider uses for pane reads.
type paneFilter int

const (
	// filterGeneric is the default agent-pane filter used by every harness
	// except Codex.
	filterGeneric paneFilter = iota
	// filterCodex uses the Codex-specific pane filter.
	filterCodex
)

// StateMode describes how a harness reports activity/state to questmaster. It
// is the single declared source for the runtime distinctions that callers
// (e.g. internal/message) previously hardcoded as agent-name checks.
type StateMode int

const (
	// StateNative covers harnesses whose pane is read directly and which do
	// not drive a hook/sidecar activity stream that callers consume for
	// structured reads or relay gating (Claude, Codex).
	StateNative StateMode = iota
	// StateSidecar covers Pi-style harnesses that emit the activity-sidecar
	// event stream (Pi) and share the rich read path.
	StateSidecar
	// StatePlugin covers harnesses whose activity state is driven by an
	// installed plugin event stream (OpenCode).
	StatePlugin
)

// Spec is the static, per-agent metadata that does not vary between sessions:
// identity, the resume/env key naming, the binary discovery hints, and the
// pane-filter choice. It is the single place a new harness declares the rote
// half of the Agent interface; the behavioural half (BuildCmd, and any
// PreLaunchSetup) stays in the provider source file.
type Spec struct {
	Name           string
	DisplayName    string
	Description    string
	DefaultCLI     string
	ResumeKey      string
	ResumeFileName string
	EnvVar         string
	BinaryEnvVar   string
	FallbackPath   string
	Filter         paneFilter
	State          StateMode
}

// base implements the boilerplate half of the Agent interface from a Spec.
// Providers embed it and override only what genuinely differs (BuildCmd is
// required; Claude additionally overrides PreLaunchSetup). The three role
// prompts are shared verbatim across every real harness, so they live here.
type base struct {
	spec Spec
	cli  string
}

// newBase resolves the configured CLI (falling back to the Spec default) and
// returns a base ready to embed.
func newBase(spec Spec, cfg AgentConfig) base {
	cli := cfg.CLI
	if cli == "" {
		cli = spec.DefaultCLI
	}
	return base{spec: spec, cli: cli}
}

func (b base) Name() string        { return b.spec.Name }
func (b base) DisplayName() string { return b.spec.DisplayName }
func (b base) Description() string { return b.spec.Description }
func (b base) Binary() string      { return b.cli }

func (b base) ResumeKey() string      { return b.spec.ResumeKey }
func (b base) ResumeFileName() string { return b.spec.ResumeFileName }
func (b base) EnvVar() string         { return b.spec.EnvVar }
func (b base) BinaryEnvVar() string   { return b.spec.BinaryEnvVar }
func (b base) FallbackPath() string   { return b.spec.FallbackPath }

func (b base) MasterPrompt() string     { return masterPromptWithGuide() }
func (b base) StandalonePrompt() string { return standalonePrompt }
func (b base) WorkerPrompt() string     { return workerPrompt }

func (b base) PreLaunchSetup(context.Context, TmuxClient, string) error { return nil }

func (b base) FilterPaneLines(raw string, max int) []string {
	if b.spec.Filter == filterCodex {
		return tmux.FilterCodexLines(raw, max)
	}
	return tmux.FilterAgentLines(raw, max)
}
