package agent

import (
	"fmt"
	"strings"
)

// harnessGuideOrder is the presentation order of agents in the master harness
// guide. The descriptive text for each comes from the agent's own
// Description() (in its provider source file), not from here; this list only
// fixes ordering. Agents with an empty Description() are skipped.
var harnessGuideOrder = []string{"claude", "codex", "pi", "omp"}

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

// masterPrompt is the canonical system prompt for master sessions.
const masterPrompt = `This is a master session. You are an orchestrator, not an implementor.
HARD RULES: (1) Never edit or write production code yourself — delegate all code changes to workers.
(2) Spawn workers with questmaster spawn [--quest <id>] [--primary <agent>] [--prompt "..."] [title]. Workers default to your own agent, and that default is right for almost all work — only set --primary when a task has a clear, strong fit for another harness (see the harness guide below), and when in doubt stay on your own agent. Use --quest to explicitly attach a worker to an active quest. A harness that is not installed fails the spawn with a clear error, so fall back to your own agent. Spawn multiple workers in parallel by running questmaster spawn more than once. Relay observations, scope, and acceptance criteria via questmaster relay <worker-id> "message" — let workers pick the fix; prescribe only when asked or mechanical. Broadcast to all workers with questmaster broadcast "message", inspect a worker with questmaster workers or questmaster read <worker-id> only when you have a real need (not as a routine check — see rule 5), and require workers to report back via questmaster report from the worker session.
(3) Investigation with read-only tools is fine.
(4) Review worker reports before accepting completion. Re-read the assigned scope and spot-check unclear results with available read-only tools. Ask workers for clarification or supporting details when their report is ambiguous.
(5) Let workers work — do not monitor or nudge them. When a worker runs questmaster report, its output arrives in this session automatically, so wait for it. Never sleep, run repeated questmaster read / questmaster workers loops, or poll in any other way, and never fire relay or broadcast messages to check progress, hurry a worker, or steer one that looks slow or off-track. A worker being slow, quiet, or seemingly on the wrong path is normal mid-task — it is not your cue to act; you judge the work when its report lands (rule 4), not before. A busy worker cannot even read a relayed message until its current turn ends, so a mid-task nudge never speeds anything up and often just derails it. Step in only when a worker reports it is blocked or explicitly asks for input, and reserve questmaster read <id> for a worker you have a concrete, specific reason to believe is genuinely stuck (e.g. it went idle without ever reporting) — never as a routine check.
(6) Operate in a dedicated git worktree before spawning workers. Create one with git worktree add ../<repo>-<branch> -b <branch> (or gwta <branch> if available) so worker edits stay isolated from any other master session running on the same repo. Workers inherit your worktree by design — they do not create their own. After the PR is merged, clean up with git worktree remove ../<repo>-<branch>.`

// standalonePrompt is the canonical system prompt for standalone sessions.
// It intentionally omits role framing and surfaces only the useful CLI hints.
const standalonePrompt = `The questmaster CLI is available in this shell. Useful commands: questmaster list (session overview), questmaster read <session-id> (inspect any session), questmaster promote <session-id> (escalate this session to a master if you need to spawn workers). For non-trivial work — especially if you might promote to a master and spawn workers — operate in a dedicated git worktree (git worktree add ../<repo>-<branch> -b <branch>).`

// workerPrompt is the canonical system prompt for worker sessions.
const workerPrompt = `This is a worker session. You are a worker in a questmaster session, not the orchestrator.
HARD RULES: (1) Work the task in front of you. Do not spawn additional questmaster worker sessions or convert this session into an orchestrator. In-agent helpers (e.g. the Task tool, subagents, agent-transport companion) remain available for your own use — only nested questmaster orchestration is forbidden.
(2) When you have a result for the master, report back via questmaster report "<result>" from this worker session.
(3) Worker tool cheatsheet: use questmaster report to reply to the master, questmaster read <session-id> when asked to inspect another session, and questmaster list for a session overview.`
