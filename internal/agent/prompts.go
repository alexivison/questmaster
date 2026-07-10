package agent

import (
	_ "embed"
	"fmt"
	"strings"
)

// harnessGuideOrder is the presentation order of agents in the master harness
// guide. It is derived from providerDefs (the single source of truth), so the
// guide order matches the declared built-in order. The descriptive text for
// each comes from the agent's own Description() (in its provider source file),
// not from here. Agents with an empty Description() are skipped.
var harnessGuideOrder = guideOrder()

func guideOrder() []string {
	out := make([]string, 0, len(providerDefs))
	for _, d := range providerDefs {
		out = append(out, d.spec.Name)
	}
	return out
}

// masterPromptWithGuide returns the shared master role prompt followed by a
// harness guide. The role framing is shared across agents and lives in this
// file; each per-harness blurb is owned by its provider via Description().
func masterPromptWithGuide() string {
	guide := harnessGuide()
	if guide == "" {
		return masterPrompt
	}
	return masterPrompt +
		"\nHarness guide (capability reference, not a routing rule — keep your own agent unless a task clearly calls for another):\n" +
		guide
}

// harnessGuide assembles "- <name>: <description>" lines from each agent's
// own Description(), in harnessGuideOrder.
func harnessGuide() string {
	var b strings.Builder
	for _, name := range harnessGuideOrder {
		ctor, ok := providerConstructors[name]
		if !ok {
			continue
		}
		a := ctor(AgentConfig{})
		desc := strings.TrimSpace(a.Description())
		if desc == "" {
			continue
		}
		fmt.Fprintf(&b, "- %s: %s\n", a.Name(), desc)
	}
	return strings.TrimRight(b.String(), "\n")
}

// Prompt text lives in prompts/*.md (not here) so it can be read and edited
// as plain markdown instead of Go string literals. Each file holds one
// self-contained fragment; the numbered "common guide" / "quest guide" /
// "artifact guide" rules are appended by the role prompts below so the
// shared fragments stay unnumbered and reusable across roles.

//go:embed prompts/artifact_guide.md
var artifactGuideMD string

//go:embed prompts/common_guide.md
var commonGuideMD string

//go:embed prompts/quest_guide.md
var questGuideMD string

//go:embed prompts/master.md
var masterPromptMD string

//go:embed prompts/worker.md
var workerPromptMD string

var artifactPromptGuide = strings.TrimSpace(artifactGuideMD)

// commonPromptGuide covers the questmaster CLI surface (list/read/promote),
// the sub-agent vs Questmaster worker delegation boundary, and the
// worktree-before-spawn hint. It is injected into every role's prompt below.
var commonPromptGuide = strings.TrimSpace(commonGuideMD)

var questPromptGuide = strings.TrimSpace(questGuideMD)

// masterPrompt is the canonical system prompt for master sessions.
var masterPrompt = strings.TrimRight(masterPromptMD, "\n") + `
(7) ` + commonPromptGuide + `
(8) ` + questPromptGuide + `
(9) ` + artifactPromptGuide

// standalonePrompt is the canonical system prompt for standalone sessions:
// just the common guide plus the quest/artifact guides, no role-specific
// rules.
var standalonePrompt = commonPromptGuide + " " + questPromptGuide + " " + artifactPromptGuide

// workerPrompt is the canonical system prompt for worker sessions.
var workerPrompt = strings.TrimRight(workerPromptMD, "\n") + `
(4) ` + commonPromptGuide + `
(5) ` + questPromptGuide + `
(6) ` + artifactPromptGuide
