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
	if !strings.Contains(got, "being a master does not mean every task needs a worker") || !strings.Contains(got, "Set --agent only when another harness is a clear fit") {
		t.Errorf("master prompt lost its shared role framing")
	}
	if strings.Contains(got, "promote") {
		t.Errorf("master prompt still mentions promotion")
	}
}

func TestMasterPromptWorkersUseExplicitCWD(t *testing.T) {
	got := masterPromptWithGuide()
	for _, want := range []string{
		"Before spawning an implementation worker, create a dedicated worktree",
		"questmaster spawn --cwd <worktree> <title>",
		"Worker titles must be explicit and no longer than 16 Unicode characters (runes)",
		"do not rely on the prompt to name the worker",
		"base required by the repository (main when none is specified)",
		"Worker manifest cwd is fixed at launch",
		"Do not use sleep, polling, or watch loops to monitor workers",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("master prompt missing worker workflow hint %q:\n%s", want, got)
		}
	}
}

func TestMasterPromptUsesDirectWorkByDefault(t *testing.T) {
	got := masterPromptWithGuide()
	for _, want := range []string{
		"Work directly by default on small, single-focus, quick tasks",
		"Do not spawn a worker just to delegate a simple task",
		"Delegate multi-step implementation",
		"long-running work",
		"when the user asks you to delegate",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("master prompt missing direct-work policy %q:\n%s", want, got)
		}
	}
}

func TestMasterPromptDisambiguatesSubagentsAndWorkers(t *testing.T) {
	got := masterPromptWithGuide()
	for _, want := range []string{
		"Use sub-agents for explicit sub-agent requests",
		"Use Questmaster workers for Questmaster worker, session, or worktree-isolation requests",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("master prompt missing delegation boundary %q:\n%s", want, got)
		}
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

func TestSessionPromptsUseSendForMessaging(t *testing.T) {
	if !strings.Contains(masterPromptWithGuide(), `questmaster send <session-id> "message"`) ||
		!strings.Contains(masterPromptWithGuide(), "masters use questmaster send all to broadcast") {
		t.Fatal("master prompt must use send for direct and broadcast messages")
	}
	if !strings.Contains(workerPrompt, `questmaster send master "<result>"`) {
		t.Fatal("worker prompt must use send master for reports")
	}
}

func TestSessionPromptsDescribeCommonGuide(t *testing.T) {
	for name, got := range map[string]string{
		"master": masterPromptWithGuide(),
		"worker": workerPrompt,
	} {
		t.Run(name, func(t *testing.T) {
			for _, want := range []string{
				"questmaster help",
				"questmaster <command> --help",
				"questmaster spawn --cwd <worktree> <title>",
				"A worker title is required and may contain at most 16 Unicode characters (runes)",
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

func TestSessionPromptsPreferQuestmasterPRAlerts(t *testing.T) {
	for name, prompt := range map[string]string{"master": masterPromptWithGuide(), "worker": workerPrompt} {
		t.Run(name, func(t *testing.T) {
			for _, phrase := range []string{"questmaster pr watch <url>", "questmaster pr events <ref> --unread", "end the turn", "gh pr checks --watch", "gh run watch", "Claude Monitor", "ScheduleWakeup", "Codex watch loops"} {
				if !strings.Contains(prompt, phrase) {
					t.Fatalf("%s prompt missing PR alert rule %q", name, phrase)
				}
			}
		})
	}
}

func TestSessionPromptsDescribeArtifactRegistration(t *testing.T) {
	for name, got := range map[string]string{
		"master": masterPromptWithGuide(),
		"worker": workerPrompt,
	} {
		t.Run(name, func(t *testing.T) {
			for _, want := range []string{
				"questmaster artifact add /absolute/path/to/file --label \"Readable title\"",
				"$QUESTMASTER_STATE_ROOT/artifacts/projects/<project-slug>/",
				"~/.questmaster-state/artifacts/projects/<project-slug>/",
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
		"master": masterPromptWithGuide(),
		"worker": workerPrompt,
	} {
		t.Run(name, func(t *testing.T) {
			for _, want := range []string{
				"questmaster quest --help",
				"questmaster quest ls <id>...",
				"questmaster quest start <id>...",
				"Selected quests must share one project",
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
