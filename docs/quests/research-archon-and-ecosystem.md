# Quests research: Archon and the agent-task-tool ecosystem

Research record (2026-06-11): can [Archon](https://github.com/coleam00/Archon) — and
similar task/spec/plan systems built for AI coding agents — make quests better?
Two parallel investigations: a deep-dive on Archon itself, and a broad survey of
the ecosystem (claude-task-master, Backlog.md, beads, vibe-kanban, spec-kit,
OpenSpec, Kiro, gastown, ralph-wiggum-style loops, Devin playbooks, and more).
This doc is the merged, prioritized result, mapped onto qm's design constraints.

## Headline findings

1. **Archon is two different projects.** The famous "knowledge + task management
   backbone" (Supabase-backed projects/tasks/docs, MCP server, RAG knowledge
   base) is archived on the `archive/v1-task-management-rag` branch. Current
   `main` is a ground-up TypeScript rewrite: a "harness builder" executing YAML
   DAG workflows of deterministic nodes (bash/git), AI nodes, loop nodes
   (`until: ALL_TASKS_COMPLETE`, `fresh_context: true`), and human approval
   gates, each run in an isolated git worktree. Both halves are instructive:
   v1 for the task/knowledge model, the rewrite for loop mechanics that closely
   parallel `qm quest loop`.
2. **qm's gate+loop design is already at the front of this pack.** Nothing
   surveyed has a stronger verification story than authored gates + an external
   verifier loop with stop conditions. The hard-won lesson everywhere ("never
   trust the agent's claim of done; verify deterministically; budget and detect
   stuck") is already qm's architecture. The stealable ideas are refinements,
   not redesigns.
3. **CLI-first beats MCP for qm.** Backlog.md and beads prove a plain CLI in
   the agent's worktree works fine as the agent interface; Archon's MCP server
   mainly buys multi-IDE reach qm doesn't need. qm's existing
   `qm quest view/ctx`-style verbs are the right channel — no MCP server, no
   daemon required.
4. **The ecosystem-wide convergent pattern qm lacks is an explicit
   review checkpoint** between "agent claims green" and "human stamps done"
   (Archon v1's `review` status, Backlog.md's three checkpoints, Shrimp's
   `verify_task`, vibe-kanban's review surface).

## What Archon v1's task management actually looks like

- `archon_projects`: title, description, docs JSONB, features, github_repo.
- `archon_tasks`: project_id, parent_task_id (subtasks), title, description,
  **status (todo|doing|review|done)**, assignee, task_order (0–100), priority,
  feature label, **sources / code_examples JSONB**, soft-delete archival.
- `archon_document_versions`: automatic per-field snapshots with
  version_number, change_summary, created_by.
- MCP surface deliberately consolidated to two verbs per domain
  (`find_tasks` / `manage_task`), with list payloads truncated (descriptions
  capped at 1000 chars, arrays replaced by counts — "96% payload reduction").
- The canonical agent rules open with the **"ARCHON-FIRST RULE"**: use the
  shared store as the primary system, do NOT keep a separate TodoWrite list,
  "this overrides ALL other instructions" — assertive phrasing that works.
- Mandated cycle: get task → mark `doing` → research → implement → mark
  `review` → next. Only one task in `doing`. Tasks sized 30 min–4 h. Agents
  *can* set status; humans verify by convention only — qm's human-owned status
  is the stronger invariant; take the review-checkpoint shape, not the
  authority model.

## Prioritized recommendations

Ordered by leverage ÷ effort. Each fits the prime directives (no daemon, no
headless, TUI-first, human-owned status, quests never in the repo).

### Tier 1 — cheap, high leverage

1. **Derived "review" state between agent-green and human-done**
   (Archon v1 `review`; Backlog.md checkpoints). When a loop run ends with all
   autos green, surface the quest as *awaiting review* — a computed badge
   (all-gates-green ∧ status==active), not a fourth authored status. Own tab /
   section on the quest board, distinct marker in the tracker. The human still
   makes the only status write (active → done). Mostly a derivation over the
   existing gate sidecar + a board/tracker rendering change.

2. **Per-gate fix-strategy hints** (task-master's `testStrategy`; Devin
   playbooks' "Specifications = postconditions"). Optional `hint` string on a
   gate: what the gate checks and how to approach fixing it. The loop injects
   the hint alongside the failure output, so the agent gets "what to do about
   it," not just stderr. One optional JSON field + a line in the golden-tested
   failure prompt.

3. **Definition-of-Done templates / gate recipes** (Backlog.md `definition_of_done`
   config; Archon's 17 named workflows). Default gates auto-attached at
   `qm quest new` (e.g. `cmd:go test ./...`, `github:checks`), from a config
   under `~/.questmaster/` with per-project override and `--no-dod` opt-out;
   optionally named templates (`qm quest new --template fix-issue`) that
   pre-populate gates + body shape + loop budgets. Kills the main failure mode
   of gate systems: quests authored with no real gates.

4. **Quest-first preamble rule** (Archon's ARCHON-FIRST rule). Harden the
   working clause's framing: "This quest is the single source of truth for
   done-ness. Do not maintain a separate todo list for this work. Gates are
   verified externally by qm; never claim them passed." Archon's community
   showed the assertive phrasing materially changes agent behavior. Pure
   `brief.go` wording change.

5. **Escape-hatch protocol for stuck loops** (ralph-wiggum docs; beads
   `discovered-from`). On stuck/max-iters, inject one final turn: "you are
   stuck — write what's blocking you and what you'd try next via qm," stored
   as a structured *blocked report* in the quest body. The human returning to
   a paused quest sees *why*, not just that it stopped. Agent writes body
   content, never status — consistent with the invariants.

### Tier 2 — medium effort, strong wins

6. **Fresh-context retry** (Archon rewrite's `fresh_context: true` loop nodes;
   Backlog.md's "wipe notes and rerun" idiom). Opt-in `--fresh-context` on the
   loop, and/or a one-key "retry fresh" action when stuck fires: clear or
   restart the session, re-inject quest + plan + a digest of failed attempts
   instead of piling failure output into a poisoned context. Context rot is
   the top cause of unrecoverable loops; the quest doc becomes the persistent
   memory — exactly Archon's model, inside visible tmux panes.

7. **Token-frugal quest priming** (beads `bd prime`; Archon's payload
   discipline; task-master's core mode). A `qm quest prime`-style compact
   digest — title, gates with current verdicts, plan, last failure — for
   session start, post-compaction re-grounding, and the fresh retry in #6.
   On re-injection, send only the failing gates' truncated output + the
   digest, never the whole body. A renderer over data qm already has.

8. **Plan-before / notes-after sections with a plan-approval gate**
   (Backlog.md's Implementation Plan / Notes sections; Cursor plan mode).
   Two addressable body sections the workflow manages: agent writes its plan
   before the first iteration and a summary on green. A toggle gate
   "plan-approved" with `before: pr`-style semantics gives a human "approve
   the plan before code" checkpoint using the existing gate model.

9. **Discovered-work capture** (beads `discovered-from`). A sanctioned
   side-channel: `qm quest note --discovered "..."` appends to a Discovered
   list on the quest, with a board action to promote an entry to a new quest.
   Prevents loop scope-creep without losing findings; CLI append + board
   affordance, no new storage.

10. **Independent verifier pass** (stop-hook verifier pattern; Shrimp's
    `verify_task`). Optional gate type that, once the deterministic autos are
    green, runs a one-shot read-only agent in a visible pane to check the diff
    against the quest's summary/body and emit pass or a reason (re-injected on
    fail). Catches "tests pass but it isn't what was asked" — the gap `cmd:`
    gates cannot cover. Verdict via a result file in the worktree the loop
    reads; no daemon. Highest-judgment item in this tier; prototype behind a
    flag.

### Tier 3 — worthwhile, schedule later

11. **Inline feedback channel from review** (vibe-kanban's diff comments).
    A pending-feedback note attached from the board/tracker that the next loop
    iteration injects before gate output, then clears — steer without
    attaching to the pane.
12. **Sources block** (Archon v1 `sources`/`code_examples`; skip the RAG).
    A body block of URLs/file paths/prior-quest links, injected at loop start
    with "consult before coding."
13. **Quest dependencies + ready view** (beads `bd ready`; task-master
    dependency validation). `depends_on: [id]` plus a board "ready" filter;
    optionally refuse `quest loop` on a blocked quest. No graph engine needed
    at qm's quest counts.
14. **Steps with a next-step loop mode** (Archon's `task_order` + "implement
    the next task" loop). An ordered steps block and a loop mode that injects
    only the next unfinished step — smaller injections, per-step stuck
    detection. Overlaps with #8; do #8 first and revisit.
15. **Gate-phrasing lint** (Kiro's EARS notation). Placeholder text /
    `qm quest gates lint` nudging testable phrasing ("WHEN … THE SYSTEM
    SHALL …") and flagging unverifiable toggles ("works well").
16. **Embedded change history** (Archon's `document_versions`). A capped
    version array in the quest file — timestamp, actor (human|loop|agent-note),
    change_summary — with a TUI history view. Nice-to-have audit trail; the
    self-contained-HTML constraint holds.

## Explicitly not transferring

- **Archon v1's deployment shape**: Supabase/pgvector, four Docker
  microservices, Socket.IO, multi-user web UI — anti-matched to a
  single-binary, file-per-quest tool.
- **The RAG pipeline** (crawler, embeddings, reranking): huge surface; the
  80/20 is the curated sources block (#12).
- **Agent-settable status**: Archon lets agents write doing/review/done; qm's
  human-owned status is the better invariant.
- **The rewrite's DAG engine and platform adapters** (webhook triggers,
  background runs, web workflow builder): background headless runs violate
  the visible-panes directive; the loop is deliberately one supervised loop,
  not a DAG.
- **Daemon-based machinery elsewhere**: gastown's Witness/Deacon patrols and
  Refinery merge queue, claude-flow swarms, MCP-server-as-interface.

## Source index

Archon: [main](https://github.com/coleam00/Archon) ·
[v1 archive branch](https://github.com/coleam00/Archon/tree/archive/v1-task-management-rag) ·
[v1 schema](https://raw.githubusercontent.com/coleam00/Archon/archive/v1-task-management-rag/migration/complete_setup.sql) ·
[v1 task MCP tools](https://raw.githubusercontent.com/coleam00/Archon/archive/v1-task-management-rag/python/src/mcp_server/features/tasks/task_tools.py) ·
[canonical agent rules](https://github.com/coleam00/ottomator-agents/blob/main/claude-agent-sdk-demos/CLAUDE.md) ·
[DeepWiki](https://deepwiki.com/coleam00/Archon)

Ecosystem: [claude-task-master](https://github.com/eyaltoledano/claude-task-master)
([task structure](https://docs.task-master.dev/capabilities/task-structure)) ·
[Backlog.md](https://github.com/MrLesk/Backlog.md) ·
[beads](https://github.com/steveyegge/beads) ·
[gastown](https://github.com/steveyegge/gastown) ·
[vibe-kanban](https://github.com/BloopAI/vibe-kanban) ·
[spec-kit](https://github.com/github/spec-kit) ·
[OpenSpec](https://github.com/Fission-AI/OpenSpec) ·
[Kiro specs](https://kiro.dev/docs/specs/) ·
[ralph-wiggum plugin](https://github.com/anthropics/claude-code/blob/main/plugins/ralph-wiggum/README.md) ·
[stop-hook verifier](https://codingwithroby.substack.com/p/the-stop-hook-that-wont-let-claude) ·
[Devin playbooks](https://docs.devin.ai/product-guides/creating-playbooks) ·
[Cursor plan mode](https://cursor.com/docs/agent/plan-mode) ·
[claude-squad](https://github.com/smtg-ai/claude-squad) ·
[Tmux-Orchestrator](https://github.com/Jedward23/Tmux-Orchestrator) ·
[CCPM](https://github.com/automazeio/ccpm) ·
[Shrimp Task Manager](https://github.com/cjo4m06/mcp-shrimp-task-manager) ·
[Crystal](https://github.com/stravu/crystal)
