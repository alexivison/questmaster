package agent

import (
	"context"

	"github.com/anthropics/ai-party/tools/party-cli/internal/tmux"
)

// Stub is a minimal reference provider for future agent adapters.
type Stub struct {
	cli string
}

// NewStub constructs the example stub provider.
func NewStub(cfg AgentConfig) *Stub {
	cli := cfg.CLI
	if cli == "" {
		cli = "stub"
	}
	return &Stub{cli: cli}
}

func (s *Stub) Name() string                                             { return "stub" }
func (s *Stub) DisplayName() string                                      { return "Stub" }
func (s *Stub) Binary() string                                           { return s.cli }
func (s *Stub) BuildCmd(CmdOpts) string                                  { return `echo "stub agent - not a real CLI"` }
func (s *Stub) ResumeKey() string                                        { return "stub_resume_id" }
func (s *Stub) ResumeFileName() string                                   { return "stub-resume-id" }
func (s *Stub) EnvVar() string                                           { return "STUB_SESSION_ID" }
func (s *Stub) MasterPrompt() string                                     { return "" }
func (s *Stub) WorkerPrompt() string                                     { return "" }
func (s *Stub) BinaryEnvVar() string                                     { return "STUB_BIN" }
func (s *Stub) FallbackPath() string                                     { return "stub" }
func (s *Stub) PreLaunchSetup(context.Context, TmuxClient, string) error { return nil }

func (s *Stub) FilterPaneLines(raw string, max int) []string {
	return tmux.FilterAgentLines(raw, max)
}

func (s *Stub) IsActive(string, string) (bool, error) { return false, nil }
