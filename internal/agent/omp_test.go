package agent

import (
	"strings"
	"testing"

	"github.com/alexivison/questmaster/internal/quests/quest"
)

func TestOmpMetadata(t *testing.T) {
	t.Parallel()

	o := NewOmp(AgentConfig{})
	if o.Name() != "omp" || o.DisplayName() != "oh-my-pi" || o.Binary() != "omp" {
		t.Fatalf("metadata: name=%q display=%q binary=%q", o.Name(), o.DisplayName(), o.Binary())
	}
	if o.ResumeKey() != "omp_session_id" || o.EnvVar() != "OMP_SESSION_ID" {
		t.Fatalf("resume metadata: key=%q env=%q", o.ResumeKey(), o.EnvVar())
	}
	if o.BinaryEnvVar() != "OMP_BIN" || o.FallbackPath() != "~/.local/bin/omp" {
		t.Fatalf("binary metadata: env=%q fallback=%q", o.BinaryEnvVar(), o.FallbackPath())
	}
}

func TestOmpBuildCmd_MasterMergesSystemPromptAndUsesXHighThinking(t *testing.T) {
	t.Parallel()

	o := NewOmp(AgentConfig{})
	got := o.BuildCmd(CmdOpts{
		Binary:      "/usr/local/bin/omp",
		AgentPath:   "/tmp/bin:/usr/bin",
		SystemBrief: "session-specific brief",
		Role:        RoleMaster,
	})

	// omp's --append-system-prompt is last-wins, so the master prompt and the
	// brief must be merged into a single flag rather than passed twice.
	if n := strings.Count(got, "--append-system-prompt"); n != 1 {
		t.Fatalf("expected exactly one --append-system-prompt, got %d in %q", n, got)
	}
	if !strings.Contains(got, "session-specific brief") {
		t.Fatalf("merged system prompt missing brief: %q", got)
	}
	if !strings.Contains(got, quest.AuthoringClause()) {
		t.Fatalf("merged system prompt missing quest authoring clause: %q", got)
	}
	if !strings.Contains(got, "orchestrator") {
		t.Fatalf("merged system prompt missing master prompt body: %q", got)
	}
	if !strings.Contains(got, "--thinking xhigh") {
		t.Fatalf("master should request --thinking xhigh: %q", got)
	}
}

func TestOmpBuildCmd_WorkerWithResumeAndPrompt(t *testing.T) {
	t.Parallel()

	o := NewOmp(AgentConfig{})
	got := o.BuildCmd(CmdOpts{
		Binary:    "/usr/local/bin/omp",
		AgentPath: "/tmp/bin:/usr/bin",
		ResumeID:  "1f9d2a6b9c0d1234",
		Prompt:    "investigate flake",
		Role:      RoleWorker,
	})

	if !strings.Contains(got, "export PATH='/tmp/bin:/usr/bin'; exec '/usr/local/bin/omp'") {
		t.Fatalf("missing omp exec prefix: %q", got)
	}
	if !strings.Contains(got, " --resume '1f9d2a6b9c0d1234'") {
		t.Fatalf("missing --resume: %q", got)
	}
	if !strings.HasSuffix(got, " 'investigate flake'") {
		t.Fatalf("prompt should be the trailing positional user turn: %q", got)
	}
	if strings.Contains(got, "--thinking") {
		t.Fatalf("non-master omp should not set a thinking level: %q", got)
	}
}

func TestNewRegistry_OmpPrimaryFromOverride(t *testing.T) {
	cfg, err := LoadConfig(&ConfigOverrides{Primary: "omp"})
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
	if primary.Agent.Name() != "omp" {
		t.Fatalf("primary agent: got %q, want omp", primary.Agent.Name())
	}
}
