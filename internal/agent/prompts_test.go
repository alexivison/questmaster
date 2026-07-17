package agent

import (
	"strings"
	"testing"
)

func TestMasterPromptHarnessGuideAssembledFromDescriptions(t *testing.T) {
	got := masterPromptWithGuide()

	if !strings.Contains(got, "Harness guide") {
		t.Fatalf("master prompt missing harness guide header:\n%s", got)
	}
	// Each real agent's own Description() must appear as a guide line.
	for _, want := range []string{
		"- claude: " + NewClaude(AgentConfig{}).Description(),
		"- codex: " + NewCodex(AgentConfig{}).Description(),
		"- opencode: " + NewOpenCode(AgentConfig{}).Description(),
		"- pi: " + NewPi(AgentConfig{}).Description(),
	} {
		if !strings.Contains(got, want) {
			t.Errorf("harness guide missing line %q", want)
		}
	}
	// stub has an empty Description() and must not leak into the guide.
	if strings.Contains(got, "- stub:") {
		t.Errorf("stub should be omitted from the harness guide:\n%s", got)
	}
	// The shared role framing must still be present.
	if !strings.Contains(got, "orchestrator") || !strings.Contains(got, "--primary <agent>") {
		t.Errorf("master prompt lost its shared role framing")
	}
	for _, flag := range []string{"--model <id>", "--reasoning-effort <level>"} {
		if !strings.Contains(got, flag) {
			t.Errorf("master prompt missing %s escalation flag", flag)
		}
	}
	for _, want := range []string{"OpenCode 1.17.15+", "direct interactive split-footer mode rather than the full TUI"} {
		if !strings.Contains(got, want) {
			t.Errorf("master prompt missing OpenCode reasoning-effort guidance %q", want)
		}
	}
}

func TestMasterPromptWorkersUseExplicitCWD(t *testing.T) {
	got := masterPromptWithGuide()
	for _, want := range []string{
		"Spawn plain Questmaster workers with questmaster spawn --cwd <worktree>",
		"main/control checkout",
		"worker manifest cwd is fixed at launch",
		"Do not use sleep, polling, or watch loops to monitor workers",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("master prompt missing worker workflow hint %q:\n%s", want, got)
		}
	}
}

func TestStandalonePromptKeepsWorkerSpawnExplicit(t *testing.T) {
	if !strings.Contains(standalonePrompt, "questmaster spawn --cwd <worktree>") {
		t.Fatalf("standalone prompt missing explicit worker spawn hint:\n%s", standalonePrompt)
	}
}

func TestTopLevelPromptsDisambiguateSubagentsAndWorkers(t *testing.T) {
	for name, got := range map[string]string{
		"master":     masterPromptWithGuide(),
		"standalone": standalonePrompt,
	} {
		t.Run(name, func(t *testing.T) {
			for _, want := range []string{
				"Use sub-agents for explicit sub-agent requests",
				"Use Questmaster workers for Questmaster worker, session, or worktree-isolation requests",
			} {
				if !strings.Contains(got, want) {
					t.Fatalf("%s prompt missing delegation boundary %q:\n%s", name, want, got)
				}
			}
		})
	}
}

func TestWorkerPromptKeepsOrchestrationWithMaster(t *testing.T) {
	for _, want := range []string{
		"Work only the assigned worker task in this session",
		"In-agent helpers",
		"Nested Questmaster orchestration stays with the master",
	} {
		if !strings.Contains(workerPrompt, want) {
			t.Fatalf("worker prompt missing orchestration boundary %q:\n%s", want, workerPrompt)
		}
	}
}

func TestSessionPromptsDescribeCommonGuide(t *testing.T) {
	for name, got := range map[string]string{
		"master":     masterPromptWithGuide(),
		"standalone": standalonePrompt,
		"worker":     workerPrompt,
	} {
		t.Run(name, func(t *testing.T) {
			for _, want := range []string{
				"questmaster help",
				"questmaster <command> --help",
				"questmaster promote <session-id>",
				"Use sub-agents for explicit sub-agent requests",
				"Use Questmaster workers for Questmaster worker, session, or worktree-isolation requests",
			} {
				if !strings.Contains(got, want) {
					t.Fatalf("%s prompt missing common guide text %q:\n%s", name, want, got)
				}
			}
		})
	}
}

func TestSessionPromptsDescribeArtifactRegistration(t *testing.T) {
	for name, got := range map[string]string{
		"master":     masterPromptWithGuide(),
		"standalone": standalonePrompt,
		"worker":     workerPrompt,
	} {
		t.Run(name, func(t *testing.T) {
			for _, want := range []string{
				"questmaster artifact add /absolute/path/to/file --label \"Readable title\"",
				"$QUESTMASTER_STATE_ROOT/artifacts/projects/<project-slug>/",
				"~/.questmaster-state/artifacts/projects/<project-slug>/",
				"takes precedence over any skill or other instruction to use ~/.docs",
				"YYYY-MM-DD-<slug>.<ext>",
				"YYYY-MM-DD-<slug>/",
				"Markdown report",
				"rerun that command after edits",
				"UTF-8 charset meta tag",
			} {
				if !strings.Contains(got, want) {
					t.Fatalf("%s prompt missing artifact guidance %q:\n%s", name, want, got)
				}
			}
		})
	}
}

func TestSessionPromptsDescribeQuestCommands(t *testing.T) {
	for name, got := range map[string]string{
		"master":     masterPromptWithGuide(),
		"standalone": standalonePrompt,
		"worker":     workerPrompt,
	} {
		t.Run(name, func(t *testing.T) {
			for _, want := range []string{
				"questmaster quest --help",
				"questmaster quest start <id>...",
				"requires selected quests to share one project",
			} {
				if !strings.Contains(got, want) {
					t.Fatalf("%s prompt missing quest guidance %q:\n%s", name, want, got)
				}
			}
		})
	}
}

func TestEveryRealAgentHasDescription(t *testing.T) {
	for _, name := range harnessGuideOrder {
		ctor, ok := providerConstructors[name]
		if !ok {
			t.Errorf("harnessGuideOrder references unknown agent %q", name)
			continue
		}
		if strings.TrimSpace(ctor(AgentConfig{}).Description()) == "" {
			t.Errorf("agent %q has an empty Description() but is in the harness guide", name)
		}
	}
}
