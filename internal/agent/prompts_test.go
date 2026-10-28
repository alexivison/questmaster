package agent

import (
	"strings"
	"testing"
)

func TestMasterPromptKeepsRoleFramingWithoutHarnessAdvice(t *testing.T) {
	got := NewClaude(AgentConfig{}).MasterPrompt()
	if !strings.Contains(got, "You can work directly or coordinate Questmaster workers") {
		t.Errorf("master prompt lost its shared role framing")
	}
	if strings.Contains(got, "Harness guide") {
		t.Errorf("master prompt contains harness routing advice")
	}
}

func TestMasterPromptDescribesSpawnCWD(t *testing.T) {
	got := masterPrompt
	for _, want := range []string{
		"questmaster spawn --cwd <worktree> <title>",
		"16 Unicode characters (runes)",
		"fixes the worker cwd at launch",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("master prompt missing worker workflow hint %q:\n%s", want, got)
		}
	}
}

func TestMasterPromptLeavesWorkflowChoicesOpen(t *testing.T) {
	got := masterPrompt
	for _, unwanted := range []string{
		"Delegate multi-step implementation",
		"Spawn a fresh reviewer only",
		"Use in-agent sub-agents only",
		"Set --agent only when another harness",
	} {
		if strings.Contains(got, unwanted) {
			t.Fatalf("master prompt dictates workflow with %q:\n%s", unwanted, got)
		}
	}
}

func TestWorkerPromptKeepsOrchestrationWithMaster(t *testing.T) {
	for _, want := range []string{
		"Work only the assigned worker task in this session",
		"Nested Questmaster orchestration stays with the master",
	} {
		if !strings.Contains(workerPrompt, want) {
			t.Fatalf("worker prompt missing orchestration boundary %q:\n%s", want, workerPrompt)
		}
	}
}

func TestSessionPromptsUseSendForMessaging(t *testing.T) {
	if !strings.Contains(masterPrompt, `questmaster send <session-id> "message"`) ||
		!strings.Contains(masterPrompt, "masters use questmaster send all to broadcast") {
		t.Fatal("master prompt must use send for direct and broadcast messages")
	}
	if !strings.Contains(workerPrompt, `questmaster send master "<result>"`) {
		t.Fatal("worker prompt must use send master for reports")
	}
}

func TestSessionPromptsDescribeCommonGuide(t *testing.T) {
	for name, got := range map[string]string{
		"master": masterPrompt,
		"worker": workerPrompt,
	} {
		t.Run(name, func(t *testing.T) {
			for _, want := range []string{
				"questmaster help",
				"questmaster <command> --help",
			} {
				if !strings.Contains(got, want) {
					t.Fatalf("%s prompt missing common guide text %q:\n%s", name, want, got)
				}
			}
		})
	}
	if strings.Contains(workerPrompt, "questmaster spawn") {
		t.Fatal("worker prompt must not give nested worker-spawn instructions")
	}
}

func TestSessionPromptsDescribeQuestmasterPRAlerts(t *testing.T) {
	for name, prompt := range map[string]string{"master": masterPrompt, "worker": workerPrompt} {
		t.Run(name, func(t *testing.T) {
			for _, phrase := range []string{"questmaster pr watch <url>", "[PR owner/repo#N]", "idle or done", "questmaster pr events <ref> --unread"} {
				if !strings.Contains(prompt, phrase) {
					t.Fatalf("%s prompt missing PR alert rule %q", name, phrase)
				}
			}
		})
	}
}

func TestSessionPromptsDescribeArtifactRegistration(t *testing.T) {
	for name, got := range map[string]string{
		"master": masterPrompt,
		"worker": workerPrompt,
	} {
		t.Run(name, func(t *testing.T) {
			for _, want := range []string{
				"questmaster artifact add /absolute/path/to/file --label \"Readable title\"",
				"Questmaster artifact view",
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
		"master": masterPrompt,
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
