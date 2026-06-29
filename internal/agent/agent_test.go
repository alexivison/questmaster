package agent

import (
	"context"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"

	"github.com/alexivison/questmaster/internal/quests/quest"
)

const wantClaudeDisableTipsArg = "--settings '{\"spinnerTipsEnabled\":false}'"

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
	if bindings[0].Role != RolePrimary || bindings[0].Agent.Name() != "claude" {
		t.Fatalf("primary binding: got %s/%s", bindings[0].Role, bindings[0].Agent.Name())
	}
}

func TestNewRegistry_CodexPrimaryFromOverride(t *testing.T) {
	cfg, err := LoadConfig(&ConfigOverrides{Primary: "codex"})
	if err != nil {
		t.Fatalf("LoadConfig: %v", err)
	}
	registry, err := NewRegistry(cfg)
	if err != nil {
		t.Fatalf("NewRegistry: %v", err)
	}

	primary, err := registry.ForRole(RolePrimary)
	if err != nil {
		t.Fatalf("ForRole(primary): %v", err)
	}
	if primary.Agent.Name() != "codex" {
		t.Fatalf("primary agent: got %q, want codex", primary.Agent.Name())
	}
}

func TestLoadConfig_Overrides(t *testing.T) {
	cfg, err := LoadConfig(&ConfigOverrides{Primary: "codex"})
	if err != nil {
		t.Fatalf("LoadConfig primary override: %v", err)
	}
	if got := cfg.Roles.Primary.Agent; got != "codex" {
		t.Fatalf("primary override: got %q, want codex", got)
	}
}

func TestLoadConfig_DefaultConfig(t *testing.T) {
	configRoot := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", configRoot)

	configPath := filepath.Join(configRoot, "questmaster", "config"+"."+"toml")
	if err := os.MkdirAll(filepath.Dir(configPath), 0o755); err != nil {
		t.Fatalf("mkdir ignored config dir: %v", err)
	}
	if err := os.WriteFile(configPath, []byte("[roles.primary]\nagent = \"codex\"\n"), 0o644); err != nil {
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

	primary, err := registry.ForRole(RolePrimary)
	if err != nil {
		t.Fatalf("ForRole(primary): %v", err)
	}
	if primary.Agent.Name() != "claude" {
		t.Fatalf("ForRole(primary): got %q, want claude", primary.Agent.Name())
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
	want := "export PATH='/tmp/bin:/usr/bin'; unset CLAUDECODE; exec '/usr/local/bin/claude' --permission-mode bypassPermissions " + wantClaudeDisableTipsArg + " --effort xhigh --append-system-prompt '" + claude.WorkerPrompt() + "'"
	if got != want {
		t.Fatalf("BuildCmd() = %q, want %q", got, want)
	}
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

func TestClaudeBuildCmd_StandalonePromptAndSystemBrief(t *testing.T) {
	t.Parallel()

	claude := NewClaude(AgentConfig{})
	brief := "Keep notes in the session log."
	got := claude.BuildCmd(CmdOpts{
		Binary:      "/usr/local/bin/claude",
		AgentPath:   "/tmp/bin:/usr/bin",
		Prompt:      "inspect the sidebar",
		SystemBrief: brief,
		Role:        RoleStandalone,
	})
	want := "--append-system-prompt '" + claude.StandalonePrompt() + "\n\n" + quest.AuthoringClause() + "\n\n" + brief + "'"
	if !strings.Contains(got, want) {
		t.Fatalf("BuildCmd() missing %q in %q", want, got)
	}
	if !strings.Contains(got, "-- 'inspect the sidebar'") {
		t.Fatalf("BuildCmd() should keep the standalone task as first user turn: %q", got)
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
	want := "export PATH='/tmp/bin:/usr/bin'; unset CLAUDECODE; exec '/usr/local/bin/claude' --permission-mode bypassPermissions " + wantClaudeDisableTipsArg + " --effort xhigh --append-system-prompt '" + claude.MasterPrompt() + "\n\n" + quest.AuthoringClause() + "'"
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

func TestCodexBuildCmd_WithPrompt(t *testing.T) {
	t.Parallel()

	codex := NewCodex(AgentConfig{})
	got := codex.BuildCmd(CmdOpts{
		Binary:    "/opt/homebrew/bin/codex",
		AgentPath: "/tmp/bin:/usr/bin",
		Prompt:    "inspect the workers",
		Role:      RoleWorker,
	})
	if !strings.HasSuffix(got, " 'inspect the workers'") {
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
	if !strings.HasSuffix(got, " 'tell the joke'") {
		t.Fatalf("BuildCmd() should keep the worker task as positional user turn: %q", got)
	}
}

func TestCodexBuildCmd_StandalonePromptAndSystemBrief(t *testing.T) {
	t.Parallel()

	codex := NewCodex(AgentConfig{})
	brief := "Keep notes in the tracker."
	got := codex.BuildCmd(CmdOpts{
		Binary:      "/opt/homebrew/bin/codex",
		AgentPath:   "/tmp/bin:/usr/bin",
		Prompt:      "inspect the sidebar",
		SystemBrief: brief,
		Role:        RoleStandalone,
	})
	wantConfig := configShellQuote("developer_instructions=" + strconv.Quote(codex.StandalonePrompt()+"\n\n"+quest.AuthoringClause()+"\n\n"+brief))
	if !strings.Contains(got, "-c "+wantConfig) {
		t.Fatalf("BuildCmd() missing %q in %q", "-c "+wantConfig, got)
	}
	if !strings.HasSuffix(got, " 'inspect the sidebar'") {
		t.Fatalf("BuildCmd() should keep the standalone task as positional user turn: %q", got)
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
		configShellQuote("developer_instructions="+strconv.Quote(codex.MasterPrompt()+"\n\n"+quest.AuthoringClause())) +
		" 'triage the backlog'"
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
			"master":     provider.MasterPrompt(),
			"standalone": provider.StandalonePrompt(),
			"worker":     provider.WorkerPrompt(),
		} {
			for _, token := range banned {
				if strings.Contains(prompt, token) {
					t.Fatalf("%s %s prompt contains removed token %q: %q", providerName, promptName, token, prompt)
				}
			}
		}
	}
}

func TestAuthoringClauseInjectedForMasterAndStandalone(t *testing.T) {
	t.Parallel()

	marker := "questmaster quest new" // a distinctive authoring-clause phrase
	for _, provider := range []Agent{NewClaude(AgentConfig{}), NewCodex(AgentConfig{}), NewPi(AgentConfig{}), NewOmp(AgentConfig{})} {
		master := provider.BuildCmd(CmdOpts{Binary: "/bin/x", AgentPath: "/p", Role: RoleMaster})
		if !strings.Contains(master, marker) {
			t.Errorf("%s master command missing the authoring clause", provider.Name())
		}
		standalone := provider.BuildCmd(CmdOpts{Binary: "/bin/x", AgentPath: "/p", Role: RoleStandalone})
		if !strings.Contains(standalone, marker) {
			t.Errorf("%s standalone command missing the authoring clause", provider.Name())
		}
		worker := provider.BuildCmd(CmdOpts{Binary: "/bin/x", AgentPath: "/p", Role: RoleWorker})
		if strings.Contains(worker, marker) {
			t.Errorf("%s worker command should not carry the authoring clause", provider.Name())
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
	if claude.StandalonePrompt() == "" {
		t.Fatal("Claude StandalonePrompt() is empty")
	}
	if claude.WorkerPrompt() == "" {
		t.Fatal("Claude WorkerPrompt() is empty")
	}
	if codex.MasterPrompt() == "" {
		t.Fatal("Codex MasterPrompt() is empty")
	}
	if codex.StandalonePrompt() == "" {
		t.Fatal("Codex StandalonePrompt() is empty")
	}
	if codex.WorkerPrompt() == "" {
		t.Fatal("Codex WorkerPrompt() is empty")
	}
}

func configShellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "'\\''") + "'"
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
