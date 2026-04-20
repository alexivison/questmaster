package agent

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
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
	want := "export PATH='/tmp/bin:/usr/bin'; unset CLAUDECODE; exec '/usr/local/bin/claude' --permission-mode bypassPermissions --append-system-prompt '" + claude.WorkerPrompt() + "'"
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

func TestClaudeBuildCmd_WorkerPromptAndSystemBrief(t *testing.T) {
	t.Parallel()

	claude := NewClaude(AgentConfig{})
	brief := "Deliver a short joke to the master session."
	got := claude.BuildCmd(CmdOpts{
		Binary:      "/usr/local/bin/claude",
		AgentPath:   "/tmp/bin:/usr/bin",
		Prompt:      "tell the joke",
		SystemBrief: brief,
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
	})
	wantConfig := configShellQuote("developer_instructions=" + strconv.Quote(codex.WorkerPrompt()+"\n\n"+brief))
	if !strings.Contains(got, "-c "+wantConfig) {
		t.Fatalf("BuildCmd() missing %q in %q", "-c "+wantConfig, got)
	}
	if !strings.HasSuffix(got, " 'tell the joke'") {
		t.Fatalf("BuildCmd() should keep the worker task as positional user turn: %q", got)
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
	want := "export PATH='/tmp/bin:/usr/bin'; exec '/opt/homebrew/bin/codex' --dangerously-bypass-approvals-and-sandbox -c " +
		configShellQuote("developer_instructions="+strconv.Quote(codex.MasterPrompt())) +
		" 'triage the backlog'"
	if got != want {
		t.Fatalf("BuildCmd(master) = %q, want %q", got, want)
	}
	if strings.Contains(got, "Task: triage the backlog") {
		t.Fatalf("BuildCmd(master) should not rewrite user prompt: %q", got)
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

func TestClaudeProjectSlug(t *testing.T) {
	t.Parallel()

	cases := []struct{ cwd, slug string }{
		{"/home/user/ai-party", "-home-user-ai-party"},
		{"/home/user/my.project", "-home-user-my-project"},
		{"/Users/alice/code/ai_party", "-Users-alice-code-ai-party"},
		{"/tmp/my project", "-tmp-my-project"},
		{"/home/user/.config/app", "-home-user--config-app"},
	}
	for _, tc := range cases {
		if got := claudeProjectSlug(tc.cwd); got != tc.slug {
			t.Errorf("claudeProjectSlug(%q) = %q, want %q", tc.cwd, got, tc.slug)
		}
	}
}

func writeTranscript(t *testing.T, path string, ageBelowWindow time.Duration) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(path, []byte("{}\n"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	mtime := time.Now().Add(-ageBelowWindow)
	if err := os.Chtimes(path, mtime, mtime); err != nil {
		t.Fatalf("chtimes: %v", err)
	}
}

func writeCodexRollout(t *testing.T, path, threadID, cwd, startedAt string, age time.Duration) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}

	record := map[string]any{
		"timestamp": startedAt,
		"type":      "session_meta",
		"payload": map[string]any{
			"id":        threadID,
			"cwd":       cwd,
			"timestamp": startedAt,
		},
	}
	line, err := json.Marshal(record)
	if err != nil {
		t.Fatalf("marshal rollout: %v", err)
	}
	if err := os.WriteFile(path, append(line, '\n'), 0o644); err != nil {
		t.Fatalf("write rollout: %v", err)
	}
	mtime := time.Now().Add(-age)
	if err := os.Chtimes(path, mtime, mtime); err != nil {
		t.Fatalf("chtimes: %v", err)
	}
}

func TestClaudeIsActive(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	transcript := filepath.Join(home, ".claude", "projects", "-cwd", "sess-1.jsonl")

	cases := []struct {
		name string
		age  time.Duration // mtime = now - age; negative = no file
		want bool
	}{
		{"fresh write inside window", ActivityWindow / 2, true},
		{"just outside window", ActivityWindow + time.Second, false},
		{"no transcript yet", -1, false},
	}
	for _, tc := range cases {
		_ = os.Remove(transcript)
		if tc.age >= 0 {
			writeTranscript(t, transcript, tc.age)
		}
		got, err := NewClaude(AgentConfig{}).IsActive("/cwd", "sess-1")
		if err != nil {
			t.Fatalf("%s: IsActive: %v", tc.name, err)
		}
		if got != tc.want {
			t.Errorf("%s: IsActive = %v, want %v", tc.name, got, tc.want)
		}
	}
}

func TestClaudeIsActive_EmptyInputsReturnFalse(t *testing.T) {
	t.Parallel()

	c := NewClaude(AgentConfig{})
	for _, tc := range []struct{ cwd, resume string }{
		{"", "sess"},
		{"/cwd", ""},
		{"", ""},
	} {
		if got, err := c.IsActive(tc.cwd, tc.resume); err != nil || got {
			t.Errorf("IsActive(%q,%q) = %v,%v; want false,nil", tc.cwd, tc.resume, got, err)
		}
	}
}

func TestClaudeIsActive_ToleratesBriefIdleGap(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	transcript := filepath.Join(home, ".claude", "projects", "-cwd", "sess-1.jsonl")
	writeTranscript(t, transcript, 7*time.Second)

	got, err := NewClaude(AgentConfig{}).IsActive("/cwd", "sess-1")
	if err != nil {
		t.Fatalf("IsActive: %v", err)
	}
	if !got {
		t.Fatal("expected a brief 7s idle gap to remain active")
	}
}

func TestCodexIsActive(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	dayDir := filepath.Join(home, ".codex", "sessions", "2026", "04", "17")
	freshMatch := filepath.Join(dayDir, "rollout-2026-04-17T14-00-00-thr-xyz.jsonl")
	unrelated := filepath.Join(dayDir, "rollout-2026-04-17T13-00-00-thr-other.jsonl")

	writeTranscript(t, freshMatch, ActivityWindow/2)
	writeTranscript(t, unrelated, time.Hour) // unrelated thread ID, should not match

	// 1. Fresh match → active.
	got, err := NewCodex(AgentConfig{}).IsActive("/ignored", "thr-xyz")
	if err != nil {
		t.Fatalf("IsActive: %v", err)
	}
	if !got {
		t.Fatal("expected fresh rollout to count as active")
	}

	// 2. Age the match out of the window → inactive.
	old := time.Now().Add(-(ActivityWindow + time.Second))
	if err := os.Chtimes(freshMatch, old, old); err != nil {
		t.Fatalf("chtimes: %v", err)
	}
	got, err = NewCodex(AgentConfig{}).IsActive("/ignored", "thr-xyz")
	if err != nil || got {
		t.Errorf("expected stale rollout to be inactive, got %v / err=%v", got, err)
	}

	// 3. Thread ID with no match → inactive, no error.
	got, err = NewCodex(AgentConfig{}).IsActive("/ignored", "thr-missing")
	if err != nil || got {
		t.Errorf("expected missing rollout to be inactive, got %v / err=%v", got, err)
	}
}

func TestCodexIsActive_FreshestWinsAcrossDays(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	oldDay := filepath.Join(home, ".codex", "sessions", "2026", "04", "10")
	newDay := filepath.Join(home, ".codex", "sessions", "2026", "04", "17")
	oldRollout := filepath.Join(oldDay, "rollout-2026-04-10T00-00-00-thr-resumed.jsonl")
	newRollout := filepath.Join(newDay, "rollout-2026-04-17T14-00-00-thr-resumed.jsonl")

	writeTranscript(t, oldRollout, time.Hour)        // stale
	writeTranscript(t, newRollout, ActivityWindow/2) // fresh

	got, err := NewCodex(AgentConfig{}).IsActive("/ignored", "thr-resumed")
	if err != nil {
		t.Fatalf("IsActive: %v", err)
	}
	if !got {
		t.Fatal("expected freshest rollout across days to drive IsActive, not the oldest match")
	}
}

func TestCodexRecoverResumeIDMatchesClosestCreatedAt(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	dayDir := filepath.Join(home, ".codex", "sessions", "2026", "04", "20")
	cwd := "/repo/app"
	writeCodexRollout(t,
		filepath.Join(dayDir, "rollout-2026-04-20T09-00-00-thr-older.jsonl"),
		"thr-older", cwd, "2026-04-20T09:00:00Z", time.Hour)
	writeCodexRollout(t,
		filepath.Join(dayDir, "rollout-2026-04-20T09-05-00-thr-newer.jsonl"),
		"thr-newer", cwd, "2026-04-20T09:05:00Z", ActivityWindow/2)

	got, err := NewCodex(AgentConfig{}).RecoverResumeID(cwd, "2026-04-20T09:04:30Z")
	if err != nil {
		t.Fatalf("RecoverResumeID: %v", err)
	}
	if got != "thr-newer" {
		t.Fatalf("RecoverResumeID = %q, want %q", got, "thr-newer")
	}
}
