package agent

import (
	"context"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
)

const wantClaudeDisableTipsArg = "--settings '{\"spinnerTipsEnabled\":false,\"crossSessionInbound\":\"accept\"}'"

func TestNewRegistry_DefaultConfig(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())

	cfg, err := LoadConfig(nil)
	if err != nil {
		t.Fatalf("LoadConfig: %v", err)
	}

	registry, err := NewRegistry(cfg)
	if err != nil {
		t.Fatalf("NewRegistry: %v", err)
	}

	bindings := registry.Bindings()
	if len(bindings) != 1 {
		t.Fatalf("Bindings len: got %d, want 1", len(bindings))
	}
	if bindings[0].Role != RoleAgent || bindings[0].Agent.Name() != "claude" {
		t.Fatalf("agent binding: got %s/%s", bindings[0].Role, bindings[0].Agent.Name())
	}
}

func TestNewRegistry_CodexAgentFromOverride(t *testing.T) {
	cfg, err := LoadConfig(&ConfigOverrides{Agent: "codex"})
	if err != nil {
		t.Fatalf("LoadConfig: %v", err)
	}
	registry, err := NewRegistry(cfg)
	if err != nil {
		t.Fatalf("NewRegistry: %v", err)
	}

	agent, err := registry.ForRole(RoleAgent)
	if err != nil {
		t.Fatalf("ForRole(agent): %v", err)
	}
	if agent.Agent.Name() != "codex" {
		t.Fatalf("agent: got %q, want codex", agent.Agent.Name())
	}
}

func TestLoadConfig_Overrides(t *testing.T) {
	cfg, err := LoadConfig(&ConfigOverrides{Agent: "codex"})
	if err != nil {
		t.Fatalf("LoadConfig agent override: %v", err)
	}
	if got := cfg.Roles.Agent.Agent; got != "codex" {
		t.Fatalf("agent override: got %q, want codex", got)
	}
}

func TestLoadConfig_DefaultConfig(t *testing.T) {
	configRoot := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", configRoot)

	configPath := filepath.Join(configRoot, "questmaster", "config"+"."+"toml")
	if err := os.MkdirAll(filepath.Dir(configPath), 0o755); err != nil {
		t.Fatalf("mkdir ignored config dir: %v", err)
	}
	if err := os.WriteFile(configPath, []byte("[roles.agent]\nagent = \"codex\"\n"), 0o644); err != nil {
		t.Fatalf("write ignored config: %v", err)
	}

	cfg, err := LoadConfig(nil)
	if err != nil {
		t.Fatalf("LoadConfig: %v", err)
	}
	if want := DefaultConfig(); !reflect.DeepEqual(cfg, want) {
		t.Fatalf("LoadConfig(nil) = %#v, want %#v", cfg, want)
	}
}

func TestRegistryGetAndForRole(t *testing.T) {
	t.Parallel()

	cfg := DefaultConfig()
	registry, err := NewRegistry(cfg)
	if err != nil {
		t.Fatalf("NewRegistry: %v", err)
	}

	claude, err := registry.Get("claude")
	if err != nil {
		t.Fatalf("Get(claude): %v", err)
	}
	if claude.Name() != "claude" || claude.DisplayName() != "Claude" || claude.ResumeKey() != "claude_session_id" {
		t.Fatalf("claude metadata: got name=%q display=%q resume=%q", claude.Name(), claude.DisplayName(), claude.ResumeKey())
	}
	if _, err := registry.Get("unknown"); err == nil {
		t.Fatal("Get(unknown): expected error")
	}

	agent, err := registry.ForRole(RoleAgent)
	if err != nil {
		t.Fatalf("ForRole(agent): %v", err)
	}
	if agent.Agent.Name() != "claude" {
		t.Fatalf("ForRole(agent): got %q, want claude", agent.Agent.Name())
	}
}

func TestClaudeBuildCmd(t *testing.T) {
	t.Parallel()

	claude := NewClaude(AgentConfig{})
	got := claude.BuildCmd(CmdOpts{
		Binary:    "/usr/local/bin/claude",
		AgentPath: "/tmp/bin:/usr/bin",
		Role:      RoleWorker,
	})
	want := "export PATH='/tmp/bin:/usr/bin'; unset CLAUDECODE; exec '/usr/local/bin/claude' --permission-mode bypassPermissions " + wantClaudeDisableTipsArg + " --append-system-prompt '" + claude.WorkerPrompt() + "'"
	if got != want {
		t.Fatalf("BuildCmd() = %q, want %q", got, want)
	}
}

// TestClaudeBuildCmd_ModelOverride guards the two things that matter now that
// there is no hardcoded per-role default: no --model flag at all when nothing
// is configured, for any role, and an explicit override always winning.
func TestClaudeBuildCmd_ModelOverride(t *testing.T) {
	t.Parallel()

	claude := NewClaude(AgentConfig{})
	base := CmdOpts{Binary: "/usr/local/bin/claude", AgentPath: "/tmp/bin:/usr/bin"}

	for _, role := range []SessionRole{RoleWorker, RoleMaster} {
		got := claude.BuildCmd(withRole(base, role))
		if strings.Contains(got, "--model '") {
			t.Fatalf("role %v with no override should omit --model: %q", role, got)
		}
	}

	override := base
	override.Role = RoleWorker
	override.Model = "opus"
	got := claude.BuildCmd(override)
	if !strings.Contains(got, "--model 'opus'") {
		t.Fatalf("explicit override should win: %q", got)
	}
}

func TestModelPolicySourcesDeclareCatalogProviders(t *testing.T) {
	t.Parallel()

	for _, name := range Names() {
		policy := ModelPolicyOf(name)
		if len(policy.Sources) == 0 {
			t.Errorf("%s declares no model catalog source", name)
		}
		for _, source := range policy.Sources {
			if source.Catalog == "" {
				t.Errorf("%s has a model source with no catalog provider", name)
			}
		}
	}
	// No built-in provider offers family aliases: the suggestion list stays to
	// concrete catalog ids everywhere.
	for _, name := range Names() {
		for _, source := range ModelPolicyOf(name).Sources {
			if source.Aliases {
				t.Errorf("%s should not offer family aliases", name)
			}
		}
	}
}

func TestFamilyAlias(t *testing.T) {
	t.Parallel()

	cases := map[string]string{
		"claude-opus":  "opus",
		"claude-fable": "fable",
		"gpt-terra":    "terra",
		"gpt":          "",
		"":             "",
	}
	for family, want := range cases {
		if got := FamilyAlias(family); got != want {
			t.Errorf("FamilyAlias(%q) = %q, want %q", family, got, want)
		}
	}
}

func TestProviderBuildCmd_ResumeKeepsSessionModel(t *testing.T) {
	t.Parallel()

	opts := CmdOpts{
		Binary:     "/bin/agent",
		AgentPath:  "/p",
		ResumeID:   "existing-session",
		Role:       RoleMaster,
		Continuing: true,
	}
	for name, provider := range map[string]Agent{
		"claude":   NewClaude(AgentConfig{}),
		"codex":    NewCodex(AgentConfig{}),
		"opencode": NewOpenCode(AgentConfig{}),
		"pi":       NewPi(AgentConfig{}),
	} {
		if got := provider.BuildCmd(opts); strings.Contains(got, "--model '") {
			t.Fatalf("%s resume should not replace its saved model: %q", name, got)
		}
	}
}

// TestProviderBuildCmd_ContinuationWithoutResumeIDOmitsModelWhenUnset guards
// that a continuation with no resume ID and no configured default omits
// --model entirely, same as any other unconfigured launch — there is no
// hardcoded per-role default left to fall back to.
func TestProviderBuildCmd_ContinuationWithoutResumeIDOmitsModelWhenUnset(t *testing.T) {
	t.Parallel()

	opts := CmdOpts{Binary: "/bin/agent", AgentPath: "/p", Role: RoleMaster, Continuing: true}
	for name, provider := range map[string]Agent{
		"claude":   NewClaude(AgentConfig{}),
		"codex":    NewCodex(AgentConfig{}),
		"opencode": NewOpenCode(AgentConfig{}),
		"pi":       NewPi(AgentConfig{}),
	} {
		if got := provider.BuildCmd(opts); strings.Contains(got, "--model '") {
			t.Fatalf("%s continuation without a resume ID or configured default should omit --model: %q", name, got)
		}
	}
}

func TestProviderBuildCmd_ReasoningEffortOverride(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name string
		cmd  string
		want string
	}{
		{
			name: "claude",
			cmd:  NewClaude(AgentConfig{}).BuildCmd(CmdOpts{Binary: "/bin/claude", AgentPath: "/p", Role: RoleWorker, ReasoningEffort: "high"}),
			want: "--effort 'high'",
		},
		{
			name: "codex",
			cmd:  NewCodex(AgentConfig{}).BuildCmd(CmdOpts{Binary: "/bin/codex", AgentPath: "/p", Role: RoleWorker, ReasoningEffort: "high"}),
			want: `model_reasoning_effort="high"`,
		},
		{
			name: "pi",
			cmd:  NewPi(AgentConfig{}).BuildCmd(CmdOpts{Binary: "/bin/pi", AgentPath: "/p", Role: RoleWorker, ReasoningEffort: "high"}),
			want: "--thinking 'high'",
		},
		{
			name: "pi max",
			cmd:  NewPi(AgentConfig{}).BuildCmd(CmdOpts{Binary: "/bin/pi", AgentPath: "/p", Role: RoleWorker, ReasoningEffort: "max"}),
			want: "--thinking 'max'",
		},
		{
			name: "opencode",
			cmd:  NewOpenCode(AgentConfig{}).BuildCmd(CmdOpts{Binary: "/bin/opencode", AgentPath: "/p", Role: RoleWorker, Prompt: "inspect", ReasoningEffort: "high"}),
			want: "run --interactive --agent 'questmaster-worker' --variant 'high' 'inspect'",
		},
	}
	for _, tt := range tests {
		if !strings.Contains(tt.cmd, tt.want) {
			t.Fatalf("%s reasoning override missing %q in %q", tt.name, tt.want, tt.cmd)
		}
	}
}

func TestEffortSources(t *testing.T) {
	t.Parallel()

	for _, tt := range []struct {
		provider    string
		efforts     EffortSource
		effortModel EffortSource
	}{
		{provider: "claude", efforts: EffortSourceClaudeHelp},
		{provider: "codex", efforts: EffortSourceCodexCache, effortModel: EffortSourceCodexConfig},
		{provider: "pi", efforts: EffortSourcePiHelp},
		{provider: "opencode", efforts: EffortSourceOpenCodeModels, effortModel: EffortSourceOpenCodeConfig},
		{provider: "unknown"},
	} {
		got := SpecOf(tt.provider).Efforts
		if got != tt.efforts {
			t.Errorf("SpecOf(%q).Efforts.Source = %q, want %q", tt.provider, got, tt.efforts)
		}
		if got := SpecOf(tt.provider).EffortModel; got != tt.effortModel {
			t.Errorf("SpecOf(%q).EffortModel = %q, want %q", tt.provider, got, tt.effortModel)
		}
	}
}

func TestValidateReasoningEffort(t *testing.T) {
	t.Parallel()

	for _, tt := range []struct {
		name     string
		provider string
		effort   string
		levels   []string
		wantErr  string
	}{
		{name: "empty effort", provider: "codex", levels: []string{"low"}},
		{name: "unknown model passes through", provider: "codex", effort: "future", levels: nil},
		{name: "reported value", provider: "codex", effort: "high", levels: []string{"low", "high"}},
		{name: "unreported value rejected", provider: "codex", effort: "minimal", levels: []string{"low", "high"}, wantErr: "supported: low, high"},
		{name: "OpenCode off matches none", provider: "opencode", effort: "off", levels: []string{"none", "low"}},
	} {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			err := ValidateReasoningEffort(tt.provider, "gpt-6-luna", tt.effort, tt.levels)
			if tt.wantErr == "" && err != nil {
				t.Fatalf("ValidateReasoningEffort() = %v, want nil", err)
			}
			if tt.wantErr != "" && (err == nil || !strings.Contains(err.Error(), tt.wantErr)) {
				t.Fatalf("ValidateReasoningEffort() = %v, want error containing %q", err, tt.wantErr)
			}
		})
	}
}

// Keep serial: a parallel test fork can inherit the executable's write fd (ETXTBSY on Linux).
func TestValidateOpenCodeReasoningVersion(t *testing.T) {
	for _, tt := range []struct {
		name    string
		version string
		wantErr string
	}{
		{name: "minimum", version: "1.17.15"},
		{name: "newer", version: "1.18.0"},
		{name: "older", version: "1.17.11", wantErr: "requires 1.17.15+"},
		{name: "invalid", version: "not-a-version", wantErr: "could not parse"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			binary := filepath.Join(t.TempDir(), "opencode")
			if err := os.WriteFile(binary, []byte("#!/bin/sh\nprintf '%s\\n' '"+tt.version+"'\n"), 0o755); err != nil {
				t.Fatalf("write OpenCode fixture: %v", err)
			}
			err := ValidateOpenCodeReasoningVersion(binary)
			if tt.wantErr == "" {
				if err != nil {
					t.Fatalf("ValidateOpenCodeReasoningVersion(%q): %v", tt.version, err)
				}
				return
			}
			if err == nil || !strings.Contains(err.Error(), tt.wantErr) {
				t.Fatalf("ValidateOpenCodeReasoningVersion(%q) = %v, want %q", tt.version, err, tt.wantErr)
			}
		})
	}
}

func withRole(opts CmdOpts, role SessionRole) CmdOpts {
	opts.Role = role
	return opts
}

func TestClaudeBuildCmd_DisablesTips(t *testing.T) {
	t.Parallel()

	claude := NewClaude(AgentConfig{})
	got := claude.BuildCmd(CmdOpts{
		Binary:    "/usr/local/bin/claude",
		AgentPath: "/tmp/bin:/usr/bin",
		Role:      RoleWorker,
	})
	if !strings.Contains(got, wantClaudeDisableTipsArg) {
		t.Fatalf("BuildCmd() should disable Claude tips, got %q", got)
	}
}

func TestClaudeBuildCmd_WithResumePromptAndTitle(t *testing.T) {
	t.Parallel()

	claude := NewClaude(AgentConfig{})
	got := claude.BuildCmd(CmdOpts{
		Binary:    "/usr/local/bin/claude",
		AgentPath: "/tmp/bin:/usr/bin",
		ResumeID:  "session-123",
		Prompt:    "fix the bug",
		Title:     "Bugfix",
		Role:      RoleWorker,
	})
	for _, needle := range []string{
		"--name 'Bugfix'",
		"--resume 'session-123'",
		"-- 'fix the bug'",
	} {
		if !strings.Contains(got, needle) {
			t.Fatalf("BuildCmd() missing %q in %q", needle, got)
		}
	}
}

func TestClaudeBuildCmd_WorkerPromptAndSystemBrief(t *testing.T) {
	t.Parallel()

	claude := NewClaude(AgentConfig{})
	brief := "Deliver a short joke to the master session."
	got := claude.BuildCmd(CmdOpts{
		Binary:      "/usr/local/bin/claude",
		AgentPath:   "/tmp/bin:/usr/bin",
		Prompt:      "tell the joke",
		SystemBrief: brief,
		Role:        RoleWorker,
	})
	want := "--append-system-prompt '" + claude.WorkerPrompt() + "\n\n" + brief + "'"
	if !strings.Contains(got, want) {
		t.Fatalf("BuildCmd() missing %q in %q", want, got)
	}
	if !strings.Contains(got, "-- 'tell the joke'") {
		t.Fatalf("BuildCmd() should keep the worker task as first user turn: %q", got)
	}
}

func TestClaudeBuildCmd_Master(t *testing.T) {
	t.Parallel()

	claude := NewClaude(AgentConfig{})
	got := claude.BuildCmd(CmdOpts{
		Binary:    "/usr/local/bin/claude",
		AgentPath: "/tmp/bin:/usr/bin",
		Role:      RoleMaster,
	})
	want := "export PATH='/tmp/bin:/usr/bin'; unset CLAUDECODE; exec '/usr/local/bin/claude' --permission-mode bypassPermissions " + wantClaudeDisableTipsArg + " --append-system-prompt " + configShellQuote(claude.MasterPrompt())
	if got != want {
		t.Fatalf("BuildCmd(master) = %q, want %q", got, want)
	}
}

func TestCodexBuildCmd(t *testing.T) {
	t.Parallel()

	codex := NewCodex(AgentConfig{})
	withResume := codex.BuildCmd(CmdOpts{
		Binary:    "/opt/homebrew/bin/codex",
		AgentPath: "/tmp/bin:/usr/bin",
		ResumeID:  "thread-123",
		Role:      RoleWorker,
	})
	if !strings.Contains(withResume, " resume 'thread-123'") {
		t.Fatalf("BuildCmd(resume) missing resume subcommand: %q", withResume)
	}
	if strings.Contains(withResume, "--resume") {
		t.Fatalf("BuildCmd(resume) used --resume flag: %q", withResume)
	}

	withoutResume := codex.BuildCmd(CmdOpts{
		Binary:    "/opt/homebrew/bin/codex",
		AgentPath: "/tmp/bin:/usr/bin",
		Role:      RoleWorker,
	})
	wantConfig := configShellQuote("developer_instructions=" + strconv.Quote(codex.WorkerPrompt()))
	if !strings.Contains(withoutResume, "-c "+wantConfig) {
		t.Fatalf("BuildCmd(no resume) missing worker developer_instructions: %q", withoutResume)
	}
	if strings.Contains(withoutResume, " resume ") {
		t.Fatalf("BuildCmd(no resume) should not include resume subcommand: %q", withoutResume)
	}
}

func TestCodexBuildCmd_ExtendedReasoningEffort(t *testing.T) {
	t.Parallel()

	codex := NewCodex(AgentConfig{})
	for _, tt := range []struct {
		model  string
		effort string
	}{
		{model: "gpt-5.6-sol", effort: "max"},
		{model: "gpt-5.6-terra", effort: "ultra"},
	} {
		got := codex.BuildCmd(CmdOpts{
			Binary:          "/opt/homebrew/bin/codex",
			AgentPath:       "/tmp/bin:/usr/bin",
			Role:            RoleWorker,
			Model:           tt.model,
			ReasoningEffort: tt.effort,
		})
		want := "export PATH='/tmp/bin:/usr/bin'; exec '/opt/homebrew/bin/codex' --dangerously-bypass-approvals-and-sandbox --model '" + tt.model + "' -c " +
			configShellQuote("model_reasoning_effort="+strconv.Quote(tt.effort)) + " -c " +
			configShellQuote("developer_instructions="+strconv.Quote(codex.WorkerPrompt()))
		if got != want {
			t.Fatalf("BuildCmd(%s) = %q, want %q", tt.effort, got, want)
		}
	}
}

// TestCodexBuildCmd_ModelAndReasoningOverride guards the two things that
// matter now that there is no hardcoded per-role default: no --model or
// -c model_reasoning_effort= flag at all when nothing is configured, for any
// role, and explicit overrides always winning.
func TestCodexBuildCmd_ModelAndReasoningOverride(t *testing.T) {
	t.Parallel()

	codex := NewCodex(AgentConfig{})
	base := CmdOpts{Binary: "/opt/homebrew/bin/codex", AgentPath: "/tmp/bin:/usr/bin"}

	for _, role := range []SessionRole{RoleWorker, RoleMaster} {
		got := codex.BuildCmd(withRole(base, role))
		if strings.Contains(got, "--model '") {
			t.Fatalf("codex role %v with no override should omit --model: %q", role, got)
		}
		if strings.Contains(got, "model_reasoning_effort") {
			t.Fatalf("codex role %v with no override should omit model_reasoning_effort: %q", role, got)
		}
	}

	override := base
	override.Role = RoleWorker
	override.Model = "gpt-custom"
	if got := codex.BuildCmd(override); !strings.Contains(got, "--model 'gpt-custom'") {
		t.Fatalf("explicit override should win for codex: %q", got)
	}
}

func TestCodexBuildCmd_WithPrompt(t *testing.T) {
	t.Parallel()

	codex := NewCodex(AgentConfig{})
	got := codex.BuildCmd(CmdOpts{
		Binary:    "/opt/homebrew/bin/codex",
		AgentPath: "/tmp/bin:/usr/bin",
		Prompt:    "- inspect the workers",
		Role:      RoleWorker,
	})
	if !strings.HasSuffix(got, " -- '- inspect the workers'") {
		t.Fatalf("BuildCmd(prompt) = %q, want prompt suffix", got)
	}
}

func TestCodexBuildCmd_WorkerPromptAndSystemBrief(t *testing.T) {
	t.Parallel()

	codex := NewCodex(AgentConfig{})
	brief := "Deliver a short joke to the master session."
	got := codex.BuildCmd(CmdOpts{
		Binary:      "/opt/homebrew/bin/codex",
		AgentPath:   "/tmp/bin:/usr/bin",
		Prompt:      "tell the joke",
		SystemBrief: brief,
		Role:        RoleWorker,
	})
	wantConfig := configShellQuote("developer_instructions=" + strconv.Quote(codex.WorkerPrompt()+"\n\n"+brief))
	if !strings.Contains(got, "-c "+wantConfig) {
		t.Fatalf("BuildCmd() missing %q in %q", "-c "+wantConfig, got)
	}
	if !strings.HasSuffix(got, " -- 'tell the joke'") {
		t.Fatalf("BuildCmd() should keep the worker task as positional user turn: %q", got)
	}
}

func TestCodexBuildCmd_Master(t *testing.T) {
	t.Parallel()

	codex := NewCodex(AgentConfig{})
	got := codex.BuildCmd(CmdOpts{
		Binary:    "/opt/homebrew/bin/codex",
		AgentPath: "/tmp/bin:/usr/bin",
		Role:      RoleMaster,
		Prompt:    "triage the backlog",
	})
	want := "export PATH='/tmp/bin:/usr/bin'; exec '/opt/homebrew/bin/codex' --dangerously-bypass-approvals-and-sandbox -c " +
		configShellQuote("developer_instructions="+strconv.Quote(codex.MasterPrompt())) +
		" -- 'triage the backlog'"
	if got != want {
		t.Fatalf("BuildCmd(master) = %q, want %q", got, want)
	}
	if strings.Contains(got, "Task: triage the backlog") {
		t.Fatalf("BuildCmd(master) should not rewrite user prompt: %q", got)
	}
}

func TestPiBuildCmdUsesHookStateSidecar(t *testing.T) {
	t.Parallel()

	pi := NewPi(AgentConfig{})
	got := pi.BuildCmd(CmdOpts{
		Binary:    "/opt/homebrew/bin/pi",
		AgentPath: "/tmp/bin:/usr/bin",
		Prompt:    "inspect activity",
		Role:      RoleWorker,
	})

	want := "export PATH='/tmp/bin:/usr/bin'; exec '/opt/homebrew/bin/pi'"
	if !strings.Contains(got, want) {
		t.Fatalf("BuildCmd() missing Pi exec prefix %q in %q", want, got)
	}
	if strings.Contains(got, "PI_ACTIVITY_FILE") || strings.Contains(got, "PI_ACTIVITY_ID") {
		t.Fatalf("BuildCmd() should not configure legacy activity sidecar env: %q", got)
	}
	if !strings.HasSuffix(got, " 'inspect activity'") {
		t.Fatalf("BuildCmd() should keep the prompt as positional user turn: %q", got)
	}
}

func TestPiBuildCmdWithResume(t *testing.T) {
	t.Parallel()

	resumeID := "019dee69-5623-75c9-9317-04bf7f94e92b"
	pi := NewPi(AgentConfig{})
	got := pi.BuildCmd(CmdOpts{
		Binary:    "/opt/homebrew/bin/pi",
		AgentPath: "/tmp/bin:/usr/bin",
		ResumeID:  resumeID,
		Role:      RoleWorker,
	})
	if !strings.Contains(got, " --session '"+resumeID+"'") {
		t.Fatalf("BuildCmd(resume) missing --session UUID: %q", got)
	}
}

// TestPiBuildCmd_ModelAndThinkingOverride guards the two things that matter
// now that there is no hardcoded per-role default: no --model or --thinking
// flag at all when nothing is configured, for any role, and an explicit
// override always winning.
func TestPiBuildCmd_ModelAndThinkingOverride(t *testing.T) {
	t.Parallel()

	pi := NewPi(AgentConfig{})
	base := CmdOpts{Binary: "/opt/homebrew/bin/pi", AgentPath: "/tmp/bin:/usr/bin"}

	for _, role := range []SessionRole{RoleWorker, RoleMaster} {
		got := pi.BuildCmd(withRole(base, role))
		if strings.Contains(got, "--model '") {
			t.Fatalf("pi role %v with no override should omit --model: %q", role, got)
		}
		if strings.Contains(got, "--thinking") {
			t.Fatalf("pi role %v with no override should omit --thinking: %q", role, got)
		}
	}

	override := base
	override.Role = RoleWorker
	override.Model = "openai/custom"
	if got := pi.BuildCmd(override); !strings.Contains(got, "--model 'openai/custom'") {
		t.Fatalf("explicit override should win for pi: %q", got)
	}
}

func TestPromptsOmitCompanionAndTransportTokens(t *testing.T) {
	t.Parallel()

	providers := map[string]Agent{
		"claude":   NewClaude(AgentConfig{}),
		"codex":    NewCodex(AgentConfig{}),
		"opencode": NewOpenCode(AgentConfig{}),
		"pi":       NewPi(AgentConfig{}),
	}
	banned := []string{
		"--companion",
		"COMPANION_NOT_AVAILABLE",
		"agent-transport/scripts",
	}

	for providerName, provider := range providers {
		for promptName, prompt := range map[string]string{
			"master": provider.MasterPrompt(),
			"worker": provider.WorkerPrompt(),
		} {
			for _, token := range banned {
				if strings.Contains(prompt, token) {
					t.Fatalf("%s %s prompt contains removed token %q: %q", providerName, promptName, token, prompt)
				}
			}
		}
	}
}

func TestProviderMetadata(t *testing.T) {
	t.Parallel()

	claude := NewClaude(AgentConfig{})
	codex := NewCodex(AgentConfig{})
	opencode := NewOpenCode(AgentConfig{})

	if claude.ResumeKey() != "claude_session_id" {
		t.Fatalf("Claude ResumeKey = %q, want claude_session_id", claude.ResumeKey())
	}
	if codex.ResumeKey() != "codex_thread_id" {
		t.Fatalf("Codex ResumeKey = %q, want codex_thread_id", codex.ResumeKey())
	}
	if opencode.ResumeKey() != "opencode_session_id" {
		t.Fatalf("OpenCode ResumeKey = %q, want opencode_session_id", opencode.ResumeKey())
	}
	if claude.MasterPrompt() == "" {
		t.Fatal("Claude MasterPrompt() is empty")
	}
	if claude.WorkerPrompt() == "" {
		t.Fatal("Claude WorkerPrompt() is empty")
	}
	if codex.MasterPrompt() == "" {
		t.Fatal("Codex MasterPrompt() is empty")
	}
	if codex.WorkerPrompt() == "" {
		t.Fatal("Codex WorkerPrompt() is empty")
	}
}

func configShellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "'\"'\"'") + "'"
}

func TestClaudePreLaunchSetup_UnsetsClaudeCode(t *testing.T) {
	t.Parallel()

	client := &recordingTmuxClient{}
	if err := NewClaude(AgentConfig{}).PreLaunchSetup(context.Background(), client, "qm-test"); err != nil {
		t.Fatalf("PreLaunchSetup: %v", err)
	}

	if len(client.unsetCalls) != 2 {
		t.Fatalf("unset calls: got %d, want 2", len(client.unsetCalls))
	}
	if client.unsetCalls[0] != (unsetCall{session: "", key: "CLAUDECODE"}) {
		t.Fatalf("global unset: got %+v", client.unsetCalls[0])
	}
	if client.unsetCalls[1] != (unsetCall{session: "qm-test", key: "CLAUDECODE"}) {
		t.Fatalf("session unset: got %+v", client.unsetCalls[1])
	}
}

type unsetCall struct {
	session string
	key     string
}

type recordingTmuxClient struct {
	unsetCalls []unsetCall
}

func (c *recordingTmuxClient) UnsetEnvironment(_ context.Context, session, key string) error {
	c.unsetCalls = append(c.unsetCalls, unsetCall{session: session, key: key})
	return nil
}
