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
		"- omp: " + NewOmp(AgentConfig{}).Description(),
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
}

func TestMasterPromptQuestWorkersUseExplicitCWDAndLoop(t *testing.T) {
	got := masterPromptWithGuide()
	for _, want := range []string{
		"main/control checkout",
		"--cwd <worktree>",
		"--quest <id>",
		"questmaster quest loop <worker-id>",
		"do not follow later cd commands",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("master prompt missing quest worker workflow hint %q:\n%s", want, got)
		}
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
				"questmaster artifact add /absolute/path/to/file.html --label \"Readable title\"",
				"do not add a duplicate",
				"path-keyed",
				"viewer live-reloads selected files",
				"questmaster artifact rm <path-or-index>",
			} {
				if !strings.Contains(got, want) {
					t.Fatalf("%s prompt missing artifact guidance %q:\n%s", name, want, got)
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
