package agent

import (
	"strings"
	"testing"
)

func TestOpenCodeMetadata(t *testing.T) {
	t.Parallel()

	o := NewOpenCode(AgentConfig{})
	if o.Name() != "opencode" || o.DisplayName() != "OpenCode" || o.Binary() != "opencode" {
		t.Fatalf("metadata: name=%q display=%q binary=%q", o.Name(), o.DisplayName(), o.Binary())
	}
	if o.ResumeKey() != "opencode_session_id" || o.ResumeFileName() != "opencode-session-id" || o.EnvVar() != "OPENCODE_SESSION_ID" {
		t.Fatalf("resume metadata: key=%q file=%q env=%q", o.ResumeKey(), o.ResumeFileName(), o.EnvVar())
	}
	if o.BinaryEnvVar() != "OPENCODE_BIN" || o.FallbackPath() != "/opt/homebrew/bin/opencode" {
		t.Fatalf("binary metadata: env=%q fallback=%q", o.BinaryEnvVar(), o.FallbackPath())
	}
}

func TestOpenCodeBuildCmd_UsesAgentPromptAndExplicitModel(t *testing.T) {
	t.Parallel()

	o := NewOpenCode(AgentConfig{})
	got := o.BuildCmd(CmdOpts{
		Binary:    "/opt/homebrew/bin/opencode",
		AgentPath: "/tmp/bin:/usr/bin",
		Prompt:    "inspect activity",
		Role:      RoleWorker,
	})
	wantCmd := "export PATH='/tmp/bin:/usr/bin'; exec '/opt/homebrew/bin/opencode' --model 'openai/gpt-5.4-mini' --agent 'questmaster-worker' --prompt 'inspect activity'"
	if got != wantCmd {
		t.Fatalf("BuildCmd() = %q, want %q", got, wantCmd)
	}

	for _, want := range []string{
		"export PATH='/tmp/bin:/usr/bin'; exec '/opt/homebrew/bin/opencode'",
		" --model 'openai/gpt-5.4-mini'",
		" --agent 'questmaster-worker'",
		" --prompt 'inspect activity'",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("BuildCmd() missing %q in %q", want, got)
		}
	}
	for _, forbidden := range []string{
		"--append-system-prompt",
		"--dangerously-skip-permissions",
		"developer_instructions",
		"questmaster worker session",
	} {
		if strings.Contains(got, forbidden) {
			t.Fatalf("BuildCmd() used unsupported prompt injection %q in %q", forbidden, got)
		}
	}
}

func TestOpenCodeBuildCmd_WorkerModelPolicy(t *testing.T) {
	t.Parallel()

	o := NewOpenCode(AgentConfig{})
	base := CmdOpts{Binary: "/bin/opencode", AgentPath: "/p"}

	worker := o.BuildCmd(withRole(base, RoleWorker))
	if !strings.Contains(worker, "--model 'openai/gpt-5.4-mini'") {
		t.Fatalf("worker should get the cheaper tier: %q", worker)
	}

	// opencode's --model is required, so non-worker roles keep the configured
	// default (big-pickle) rather than dropping the flag.
	for _, role := range []SessionRole{RoleMaster, RoleStandalone} {
		got := o.BuildCmd(withRole(base, role))
		if !strings.Contains(got, "--model 'opencode/big-pickle'") {
			t.Fatalf("role %d should keep the default model: %q", role, got)
		}
	}

	override := base
	override.Role = RoleWorker
	override.Model = "openai/gpt-5.4"
	if got := o.BuildCmd(override); !strings.Contains(got, "--model 'openai/gpt-5.4'") {
		t.Fatalf("explicit override should win: %q", got)
	}
}

func TestOpenCodeBuildCmd_RoleSpecificAgentNames(t *testing.T) {
	t.Parallel()

	o := NewOpenCode(AgentConfig{})
	cases := []struct {
		role SessionRole
		want string
	}{
		{role: RoleMaster, want: " --agent 'questmaster-master'"},
		{role: RoleStandalone, want: " --agent 'questmaster-standalone'"},
		{role: RoleWorker, want: " --agent 'questmaster-worker'"},
	}
	for _, tc := range cases {
		got := o.BuildCmd(CmdOpts{Binary: "/bin/opencode", AgentPath: "/p", Role: tc.role})
		if !strings.Contains(got, tc.want) {
			t.Fatalf("BuildCmd(%v) missing %q in %q", tc.role, tc.want, got)
		}
	}
}

func TestOpenCodeBuildCmd_ResumeStillPassesAgent(t *testing.T) {
	t.Parallel()

	// Explicit opts.Model override wins over the worker default for opencode.
	o := NewOpenCode(AgentConfig{OpenCodeAgent: "qm-custom"})
	got := o.BuildCmd(CmdOpts{
		Binary:    "/bin/opencode",
		AgentPath: "/p",
		ResumeID:  "ses_0123456789abcdef",
		Role:      RoleWorker,
		Model:     "provider/model",
	})
	wantCmd := "export PATH='/p'; exec '/bin/opencode' --model 'provider/model' --agent 'qm-custom' --session 'ses_0123456789abcdef'"
	if got != wantCmd {
		t.Fatalf("BuildCmd(resume) = %q, want %q", got, wantCmd)
	}

	for _, want := range []string{
		" --model 'provider/model'",
		" --session 'ses_0123456789abcdef'",
		" --agent 'qm-custom'",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("BuildCmd(resume) missing %q in %q", want, got)
		}
	}
	if strings.Contains(got, "--continue") || strings.Contains(got, "--dangerously-skip-permissions") {
		t.Fatalf("BuildCmd(resume) must use --session, got %q", got)
	}
}

func TestDefaultConfig_OpenCodeHasExplicitModel(t *testing.T) {
	t.Parallel()

	cfg := DefaultConfig()
	opencode, ok := cfg.Agents["opencode"]
	if !ok {
		t.Fatal("DefaultConfig missing opencode agent")
	}
	if opencode.Model == "" {
		t.Fatal("DefaultConfig opencode model must be explicit")
	}
}

func TestNewRegistry_OpenCodePrimaryFromOverride(t *testing.T) {
	cfg, err := LoadConfig(&ConfigOverrides{Primary: "opencode"})
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
	if primary.Agent.Name() != "opencode" {
		t.Fatalf("primary agent: got %q, want opencode", primary.Agent.Name())
	}
}
