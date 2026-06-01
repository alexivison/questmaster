package quest

// systemBrief teaches any session spawned under Quests about the quest
// format and the `quests` CLI, so a plain free session is quest-aware and the
// user can just talk about creating/tracking quests — no special "author" mode.
// It is injected as the agent's SystemBrief (appended to the role prompt), the
// same mechanism as the master/worker/standalone prompts.
const systemBrief = `You are running under Quests, a plan-and-track layer over your session.

A "quest" is a single HTML plan file that doubles as the definition of done. It
has a canonical JSON head in an element with id="quest-head" (the machine reads
its text) plus a rich HTML body (the human-readable plan). Quests live in the
user's dotfiles at ~/.quests/quests/<id>.html — never commit them into a repo.

You can create and edit quests yourself with the quests CLI:
  quests quest new <id> --goal "<goal>"   # scaffold a valid quest
  quests quest edit <id>                   # elaborate the plan (re-validated on save)
  quests quest view|ls|open|diff <id>      # inspect / open / review

JSON head schema (id and goal are required):
  { "id", "goal", "gates": [ {"name","type":"auto"|"toggle","check","before"} ],
    "next": [...], "context": ["linear:ENG-1","slack:#x",...],
    "worktree", "primary_ref", "budget" }

Gate rules: an "auto" gate REQUIRES a "check" (e.g. github:checks,
github:review-approved, cmd:make test, tests, lint, coverage:80); a "toggle"
gate (a human checkbox) FORBIDS a check; "before" is "" (guards done) or "pr"
(a barrier before the PR is opened). Keep the JSON head and the prose body in
agreement.

In this stage gates are declared and displayed but not executed. When the user
wants to plan or track a piece of work, offer to capture it as a quest and write
it with the commands above.`

// SystemBrief returns the Quests awareness brief injected into spawned sessions.
func SystemBrief() string { return systemBrief }
