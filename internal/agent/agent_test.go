package agent

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

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
	if len(bindings) != 2 {
		t.Fatalf("Bindings len: got %d, want 2", len(bindings))
	}
	if bindings[0].Role != RolePrimary || bindings[0].Agent.Name() != "claude" {
		t.Fatalf("primary binding: got %s/%s", bindings[0].Role, bindings[0].Agent.Name())
	}
	if bindings[1].Role != RoleCompanion || bindings[1].Agent.Name() != "codex" {
		t.Fatalf("companion binding: got %s/%s", bindings[1].Role, bindings[1].Agent.Name())
	}
}

func TestNewRegistry_CodexPrimaryFromConfig(t *testing.T) {
	setupRepoWithConfig(t, `
[roles.primary]
agent = "codex"
`)

	cfg, err := LoadConfig(nil)
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

func TestNewRegistry_NoCompanion(t *testing.T) {
	setupRepoWithConfig(t, `
[roles.primary]
agent = "claude"
`)

	cfg, err := LoadConfig(nil)
	if err != nil {
		t.Fatalf("LoadConfig: %v", err)
	}
	registry, err := NewRegistry(cfg)
	if err != nil {
		t.Fatalf("NewRegistry: %v", err)
	}
	if registry.HasRole(RoleCompanion) {
		t.Fatal("HasRole(companion): got true, want false")
	}
	if _, err := registry.ForRole(RoleCompanion); err == nil {
		t.Fatal("ForRole(companion): expected error")
	}
}

func TestNewRegistry_RejectsSameProviderForBothRoles(t *testing.T) {
	t.Parallel()

	_, err := NewRegistry(&Config{
		Agents: map[string]AgentConfig{
			"codex": {CLI: "codex"},
		},
		Roles: RolesConfig{
			Primary:   &RoleConfig{Agent: "codex"},
			Companion: &RoleConfig{Agent: "codex"},
		},
	})
	if err == nil {
		t.Fatal("expected duplicate provider roles to fail")
	}
	if !strings.Contains(err.Error(), `cannot use the same agent "codex"`) {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestLoadConfig_Overrides(t *testing.T) {
	setupRepoWithConfig(t, `
[roles.primary]
agent = "claude"

[roles.companion]
agent = "codex"
`)

	cfg, err := LoadConfig(&ConfigOverrides{Primary: "codex"})
	if err != nil {
		t.Fatalf("LoadConfig primary override: %v", err)
	}
	if got := cfg.Roles.Primary.Agent; got != "codex" {
		t.Fatalf("primary override: got %q, want codex", got)
	}

	cfg, err = LoadConfig(&ConfigOverrides{Companion: "claude"})
	if err != nil {
		t.Fatalf("LoadConfig companion override: %v", err)
	}
	if cfg.Roles.Companion == nil || cfg.Roles.Companion.Agent != "claude" {
		t.Fatalf("companion override: got %+v, want claude", cfg.Roles.Companion)
	}

	cfg, err = LoadConfig(&ConfigOverrides{NoCompanion: true})
	if err != nil {
		t.Fatalf("LoadConfig no-companion override: %v", err)
	}
	if cfg.Roles.Companion != nil {
		t.Fatalf("no-companion override: got %+v, want nil", cfg.Roles.Companion)
	}
}

func TestLoadConfig_DefaultWithoutFile(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())

	cfg, err := LoadConfig(nil)
	if err != nil {
		t.Fatalf("LoadConfig: %v", err)
	}
	if cfg.Roles.Primary == nil || cfg.Roles.Primary.Agent != "claude" {
		t.Fatalf("primary default: got %+v", cfg.Roles.Primary)
	}
	if cfg.Roles.Companion == nil || cfg.Roles.Companion.Agent != "codex" {
		t.Fatalf("companion default: got %+v", cfg.Roles.Companion)
	}
}

func TestLoadConfig_ValidFile(t *testing.T) {
	setupRepoWithConfig(t, `
[agents.codex]
cli = "codex-beta"

[roles.primary]
agent = "codex"
window = 0

[roles.companion]
agent = "claude"
window = 2
`)

	cfg, err := LoadConfig(nil)
	if err != nil {
		t.Fatalf("LoadConfig: %v", err)
	}
	if got := cfg.Agents["codex"].CLI; got != "codex-beta" {
		t.Fatalf("codex cli: got %q, want codex-beta", got)
	}
	if cfg.Roles.Primary == nil || cfg.Roles.Primary.Agent != "codex" || cfg.Roles.Primary.Window != 0 {
		t.Fatalf("primary role: got %+v", cfg.Roles.Primary)
	}
	if cfg.Roles.Companion == nil || cfg.Roles.Companion.Agent != "claude" || cfg.Roles.Companion.Window != 2 {
		t.Fatalf("companion role: got %+v", cfg.Roles.Companion)
	}
}

func TestUserConfigPath_UsesXDGConfigHome(t *testing.T) {
	configRoot := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", configRoot)

	path, err := UserConfigPath()
	if err != nil {
		t.Fatalf("UserConfigPath: %v", err)
	}
	want := filepath.Join(configRoot, "party-cli", "config.toml")
	if path != want {
		t.Fatalf("UserConfigPath = %q, want %q", path, want)
	}
}

func TestLoadConfig_MissingCompanionSection(t *testing.T) {
	setupRepoWithConfig(t, `
[roles.primary]
agent = "claude"
`)

	cfg, err := LoadConfig(nil)
	if err != nil {
		t.Fatalf("LoadConfig: %v", err)
	}
	if cfg.Roles.Companion != nil {
		t.Fatalf("companion: got %+v, want nil", cfg.Roles.Companion)
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
	})
	want := "export PATH='/tmp/bin:/usr/bin'; unset CLAUDECODE; exec '/usr/local/bin/claude' --permission-mode bypassPermissions"
	if got != want {
		t.Fatalf("BuildCmd() = %q, want %q", got, want)
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

func TestClaudeBuildCmd_Master(t *testing.T) {
	t.Parallel()

	claude := NewClaude(AgentConfig{})
	got := claude.BuildCmd(CmdOpts{
		Binary:    "/usr/local/bin/claude",
		AgentPath: "/tmp/bin:/usr/bin",
		Master:    true,
	})
	want := "export PATH='/tmp/bin:/usr/bin'; unset CLAUDECODE; exec '/usr/local/bin/claude' --permission-mode bypassPermissions --effort high --append-system-prompt 'This is a **master session**. Thou art an orchestrator, not an implementor. HARD RULES: (1) Never Edit/Write production code — delegate all changes to workers. (2) Spawn workers with `party-cli spawn [title]` or `/party-dispatch`; relay follow-up instructions with `party-cli relay <worker-id> \"message\"`, inspect workers with `party-cli workers` or `party-cli read <worker-id>`, and require workers to report back via `party-cli report` from the worker session. (3) Investigation (Read/Grep/Glob/read-only Bash) is fine. See `party-dispatch` only for multi-item orchestration.'"
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
	})
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
	})
	if !strings.HasSuffix(got, " 'inspect the workers'") {
		t.Fatalf("BuildCmd(prompt) = %q, want prompt suffix", got)
	}
}

func TestCodexBuildCmd_Master(t *testing.T) {
	t.Parallel()

	codex := NewCodex(AgentConfig{})
	got := codex.BuildCmd(CmdOpts{
		Binary:    "/opt/homebrew/bin/codex",
		AgentPath: "/tmp/bin:/usr/bin",
		Master:    true,
		Prompt:    "triage the backlog",
	})
	if !strings.Contains(got, configShellQuote(codex.MasterPrompt()+"\n\nTask: triage the backlog")) {
		t.Fatalf("BuildCmd(master) missing combined master prompt: %q", got)
	}
}

func TestProviderMetadata(t *testing.T) {
	t.Parallel()

	claude := NewClaude(AgentConfig{})
	codex := NewCodex(AgentConfig{})

	if claude.ResumeKey() != "claude_session_id" {
		t.Fatalf("Claude ResumeKey = %q, want claude_session_id", claude.ResumeKey())
	}
	if codex.ResumeKey() != "codex_thread_id" {
		t.Fatalf("Codex ResumeKey = %q, want codex_thread_id", codex.ResumeKey())
	}
	if claude.MasterPrompt() == "" {
		t.Fatal("Claude MasterPrompt() is empty")
	}
	if codex.MasterPrompt() == "" {
		t.Fatal("Codex MasterPrompt() is empty")
	}
}

func configShellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "'\\''") + "'"
}

func TestClaudePreLaunchSetup_UnsetsClaudeCode(t *testing.T) {
	t.Parallel()

	client := &recordingTmuxClient{}
	if err := NewClaude(AgentConfig{}).PreLaunchSetup(context.Background(), client, "party-test"); err != nil {
		t.Fatalf("PreLaunchSetup: %v", err)
	}

	if len(client.unsetCalls) != 2 {
		t.Fatalf("unset calls: got %d, want 2", len(client.unsetCalls))
	}
	if client.unsetCalls[0] != (unsetCall{session: "", key: "CLAUDECODE"}) {
		t.Fatalf("global unset: got %+v", client.unsetCalls[0])
	}
	if client.unsetCalls[1] != (unsetCall{session: "party-test", key: "CLAUDECODE"}) {
		t.Fatalf("session unset: got %+v", client.unsetCalls[1])
	}
}

func TestCodexReadState_StaleWorking(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	startedAt := time.Now().Add(-31 * time.Minute).UTC().Format(time.RFC3339)
	payload := `{"state":"working","started_at":"` + startedAt + `"}`
	if err := os.WriteFile(filepath.Join(dir, "codex-status.json"), []byte(payload), 0o644); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}

	state, err := NewCodex(AgentConfig{}).ReadState(dir)
	if err != nil {
		t.Fatalf("ReadState: %v", err)
	}
	if state.State != "error" {
		t.Fatalf("state.State = %q, want error", state.State)
	}
	if !strings.Contains(state.Error, "stale: started ") {
		t.Fatalf("state.Error = %q, want stale marker", state.Error)
	}
}

func setupRepoWithConfig(t *testing.T, tomlBody string) string {
	t.Helper()

	root := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", root)

	path := filepath.Join(root, "party-cli", "config.toml")
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir config dir: %v", err)
	}
	if err := os.WriteFile(path, []byte(strings.TrimSpace(tomlBody)+"\n"), 0o644); err != nil {
		t.Fatalf("write config.toml: %v", err)
	}
	return path
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
