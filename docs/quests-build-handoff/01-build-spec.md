# Questmaster / Quests — Build Spec

> **Status:** design complete, pre-build · **Language:** Go · **Builds on:** the `questmaster` spine · **Runs alongside:** current `questmaster` (full instance isolation)
>
> **North star:** *A quest is the plan file you already build by hand — made first-class, viewable, editable, trackable, and machine-readable, so it also guides and gates the sessions you spawn.*

This is a handoff document for Claude Code. It describes the **full vision**, then sequences delivery into **build phases** (Stage 0 → 3). Build phases in order. Each phase ships standalone value; do not build ahead of the current phase. Stage 0 is a decision gate, not code — **read it first.**

---

## 0. Stage 0 — the gate before you build

Before writing a line of Stage 1, run the cheap test. The entire thesis (a verification loop makes agent output trustworthy) is validated in the field, but it has not been validated *for this workflow*.

**Do this:** take one real ticket. Write its gates by hand (e.g. CI green + one test command + one manual check). Run the loop manually on the *current* questmaster: spawn a session, point it at the gates, and when it reports done, check the gates yourself; on failure, paste the failure back and let it iterate. Spend a weekend, no new code.

**Kill criterion:** if the gated hand-run does **not** clearly beat "current questmaster + gate instructions in `AGENTS.md` + CI + a little discipline," then **adopt or don't build** — integrate an existing harness (Symphony's open spec, Archon) or stay with what you have. Build Stage 1 only if the test sings.

Deliverable of Stage 0: **a decision**, written down.

---

## 1. Principles

These constrain every design choice below.

- **Sessions are the substrate; a quest is an optional hat.** A session (an agent, as in questmaster today) is the unit you drive. A quest is a contract you attach *to* a session/tree. Free sessions need no quest.
- **Two stages, the quest is the boundary.** *Planning* (interactive, tmux-hosted, live master↔worker — produces the quest) vs *execution* (lightweight, headless, inbox — consumes the quest). Planning **is** quest creation.
- **One fact, one home.** Authored content lives once (the quest file); observed/runtime state lives once (the runtime record). Nothing is stored twice → drift is structurally impossible.
- **Checkability by construction.** An `auto` gate must carry a runnable check; anything unverifiable is a `toggle` (human).
- **No false done.** The agent can never self-certify; only the loop closes a quest, by measuring gates externally against the artifact. Guarantee is *no false completion*, not *success*.
- **Trust scales with gate type, not authorship.** Externally-measured-and-not-agent-defined gates can be self-attached by agents freely; agent-authored tests need human approval.
- **tmux demoted, not retired.** It is the session host for the interactive planning stage, not the message transport. Execution needs no tmux.
- **Proportional rigor.** Free session → quest with a forgiving toggle → quest with full auto-gates and walk-away. The tool spans "as light as questmaster today" to "fully autonomous," and the user picks the rung per task.

---

## 2. Glossary

- **Session** — a running agent (claude / codex / pi), with a **role**: `solo`, `master`, or `worker`.
- **Free session** — a session with no quest attached. Behaves like questmaster today.
- **Interactive vs headless** — interactive = the real native agent TUI (planning, or a promoted execution session); headless = supervisor-owned, streams events, survives terminal/tmux close (execution).
- **The layer** — how a session runs and is shown: headless supervisor, tmux pane (planning host), native full-screen (promote), or cockpit steer (no tmux).
- **Quest** — the contract + plan: one HTML file (visible JSON head + rich body) plus a definition of done (gates). The "hat."
- **Gate** — a single done-criterion, typed `auto` (runnable check) or `toggle` (human box).
- **Attempt** — a session tree working under a quest; sequential, versioned.
- **The loop** — turn-end → check gates → inject failures → repeat to budget → escalate.
- **The router** — owns message addressing/logging; delivery is mode-aware.
- **Runtime record** — the harness-written, observed state (gate results, sessions, PR/CI). Never authored.
- **Cockpit** — the three-pane TUI: agents roster | quests list | details + steer.

---

## 3. Architecture

```
┌──────────────────────────────────────────────────────────────┐
│ COCKPIT (TUI)   agents roster │ quests list │ detail + steer   │
└───────────┬───────────────────────────────────┬──────────────┘
            │ spawn · jump · promote · steer       │ open-in-browser
   ┌────────▼─────────┐                   ┌────────▼───────────┐
   │ SESSION SUBSTRATE │  ◀── router ──▶   │ QUEST STORE         │
   │  interactive (tmux)│  (mode-aware     │  files: HTML head+  │
   │  headless (supervisor) delivery)      │  body  +  schema    │
   └────────┬─────────┘                   └────────┬───────────┘
            │ events (hooks / stream-json)          │ authored
   ┌────────▼─────────┐                   ┌────────▼───────────┐
   │ GATE RUNNER +     │── reads artifact ─│ RUNTIME RECORD      │
   │ LOOP CONTROLLER   │   (worktree→PR)   │  observed state     │
   └────────┬─────────┘                   └─────────────────────┘
            │ context in / status out
   ┌────────▼──────────────────────────────────────────────────┐
   │ ADAPTERS (MCP):  Linear · Notion · Slack · GitHub           │
   └────────────────────────────────────────────────────────────┘
```

**Reuse from the existing tools:**
- `questmaster` spine — agent registry (claude/codex/pi), session spawn, hook→state machine (`working/blocked/done/idle`), per-session `state.json` / `state.jsonl`, resume-id tracking. The interactive substrate is *kept*; the runner gains a headless supervisor + input channel.
- `projdash` — its read-only GraphQL queries for Linear/GitHub become the **context + status adapters** (PR/CI display in Stage 1; gate inputs in Stage 2). No mutations beyond thin status write-back.
- **review viewer** — the `diff` command launches an external diff viewer (gh-dash style) against the quest's worktree-vs-base. `scry` is the default *because you own it and can teach it to talk to the loop* (flag-a-hunk → steer), not because it's the only option; it's swappable via flag/env (delta, difftastic, etc.). Nothing is embedded in the cockpit — review is a launched viewer, not an inline render.

**Data flow:** a planning session co-authors a quest file → quest is validated against the schema → dispatched (a session is sent on it) → the loop runs gates against the artifact, injecting failures until green or budget-out → escalation if stuck → human marks done at merge. The runtime record is written by the harness throughout; the quest file is edited only by human + planning agent.

---

## 4. The Quest — data model

**One file.** A quest is a single HTML document with two parts:

- **Canonical JSON head** — a visible code block, `id="quest-head"`. The terminal and harness parse its text content (syntax-highlight spans vanish under `.textContent`); the human reads it to audit. *One copy, both uses.*
- **Rich HTML body** — the authored plan (research, approach, diagrams, steps). The browser renders it; the terminal links to it.

**JSON head schema:**

```json
{
  "id":          "ENG-142",
  "goal":        "string (required)",
  "gates":       [
    { "name": "ci",       "type": "auto",   "check": "github:checks" },
    { "name": "pr",       "type": "auto",   "check": "github:review-approved" },
    { "name": "tests",    "type": "auto",   "check": "cmd:make test" },
    { "name": "review",   "type": "toggle", "before": "pr" },
    { "name": "ui-match", "type": "toggle" }
  ],
  "next":        ["string", "..."],
  "context":     ["linear:ENG-142", "slack:#auth", "notion:RFC-9"],
  "worktree":    "webapp/.wt/eng-142",
  "primary_ref": "linear:ENG-142",
  "budget":      5
}
```

**Check grammar** (for `auto` gates): `github:checks`, `github:review-approved`, `cmd:<shell>`, `typecheck`, `lint`, `coverage:<min>`. Validation rule: `type:"auto"` **requires** a `check`; `type:"toggle"` **forbids** one.

**Position (`before`).** Any gate may carry an optional `before` naming the transition it guards. Omitted ⇒ the gate guards `done` (the default — what every gate did until now). `before:"pr"` ⇒ the gate is a barrier the loop will not cross until it passes, so the PR isn't opened until then. A `toggle` with `before:"pr"` is the "let me review before the PR" case; the same toggle with no `before` is the end-of-quest UI/sanity check — one mechanism, two positions.

**Runtime record** (separate, harness-owned, never in the file):

```json
{
  "quest_id":     "ENG-142",
  "status":       "draft|ready|in_progress|blocked|done",
  "gate_results": { "ci": "green", "pr": "pending", "tests": "green", "ui-match": "unset" },
  "sessions":     [ { "id": "s_01", "role": "master", "agent": "claude", "state": "working" } ],
  "pr":           { "number": 441, "url": "…", "ci": "green", "review": "pending" },
  "attempts":     [ { "n": 1, "started": "…", "outcome": "aborted: scope change" } ],
  "updated_at":   "…"
}
```

**Two views (both read-only renderings, never copies):**
- **Terminal** = JSON head + live overlay of the runtime record (gate glyphs, sessions, next-steps). The cockpit index.
- **Browser** = the rich body + a status banner *injected at view-time* from head + runtime. The plan always shows current progress without hand-maintenance.

**Template & conformance:**
- Ship `quest-template.html` (the worked example) as the canonical scaffold + few-shot for the planning agent.
- **Structure → machine-enforced.** On every `quest new` / `quest edit`, parse the head, validate against the schema; on failure **refuse the quest** and feed the error back to the planner (same refuse-and-re-engage loop as gates). A malformed quest cannot be saved.
- **Meaning → human-audited.** A schema can't confirm the prose *agrees* with the head; the visible JSON lets the user spot a gate/step that's in one but not the other and tell the planner to reconcile. (Future: a `quest reconcile` command has the planner re-read the body and propose head updates.)

---

## 5. Sessions, the Layer & Navigation

- **Roles:** `solo` (default), `master`, `worker`. Master↔worker is via session roles, not a separate system.
- **Modes:** planning sessions are **interactive** (native TUI in a tmux window: TUI + shell + a compact-cockpit sidebar pane — the current questmaster layout). Execution sessions are **headless** by default and viewed in the cockpit detail pane (feed + gate/PR status + worktree + steer input). **Promote** a headless session → it spins a tmux window identical to a planning session; **demote** → back to headless, inbox drains.
- **Navigation (one switcher, two behaviors):** launch opens the cockpit. A session switcher (sidebar select / fuzzy key) lands you on any session — **tmux-switch** if interactive, **cockpit detail-focus** if headless. Jumping between *planning* sessions is the primary jump use; the sidebar is a compact cockpit riding inside each planning window.
- **Awareness roster:** all sessions across all repos, fed by hooks (interactive) and stream-json (headless); pushes alerts (blocked / gate-fail / needs-toggle).
- **Dependency / spike:** the headless detail view must be rich enough that the user rarely promotes *just to see* what an agent is doing. See §13.

---

## 6. Comms / Router

The router owns addressing, logging, and format; **delivery is mode-aware:**

| recipient | delivery |
|---|---|
| headless session | supervisor injects the turn (live) |
| interactive planning pane | live pty-write into the pane (current questmaster behavior; racing tolerated, as today) |
| solo native drive (promoted) | queue on a persisted per-session inbox + surface count on the status line → drain FIFO on demote |

Emitting is mode-independent: any agent (or the user) can `relay`/`report`, so a promoted session can still dispatch. Only *receiving* changes.

---

## 7. Gates, the Loop & Enforcement

- **Catalog** defines gate *kinds*; the quest file declares which apply, each typed. Presets: `ci`, `pr`, `tests`, `typecheck`, `lint`, `coverage`. `toggle` is the honest home for anything unverifiable (`ui-match`, `smoke`, `review`, `i-checked`); a quest may have several toggles, each a free-form human checkpoint the user must tick.
- **Gates are positioned barriers, not just end-checks.** A gate's `before` (see §4) says which transition it guards; the loop will not cross that point until the gate passes. Most guard `done`; a `toggle` with `before:"pr"` guards PR creation — that *is* the "review before PR" feature, no new primitive. Consequence: for a quest carrying a `before:"pr"` gate, the loop owns the PR-creation transition (the agent's turn ends at "changes ready in the worktree"; the loop opens the PR only once the guarding gates clear). Quests without one keep the simpler "agent opens its own PR" flow.
- **The win that isn't redundant:** Claude can watch CI/PR; codex/pi can't. The loop gives *any* agent "iterate until green" — agent-agnostic.
- **The loop (state machine):**
  ```
  turn ends → check gates → all pass? → CLOSE
                          → any fail?  → inject failures as next turn → repeat
                          → budget out → ESCALATE (notify human)
  ```
- **Async gates** are not a tight retry loop. CI is minutes; PR-approval can stall for days. The loop **suspends on events** (CI webhook/poll, PR review state) rather than busy-waiting. Define an explicit *attempt-complete* signal and a wait/escalate state.
- **Enforcement = no self-certify + external measurement + re-engage.** The agent's "done" is just turn-end; gates are measured against the artifact by the harness; the agent has no write path to gate state (snapshot at attempt launch).
- **Escalation round-trip:** budget-out / stuck / needs-toggle → notify (Slack) → human replies → quest resumes. Design the resume path explicitly.

---

## 8. Authoring & Agent-Initiated Quests

- Quests are drafted **in the planning stage** — user + master + research workers, live, reading code and linked context. The planning agent writes the head (to schema) and the rich body, conforming to the template.
- **Agents may create and self-attach quests.** Integrity holds via trust-by-gate-type: externally-measured-and-not-agent-defined gates (real CI, the existing test suite) → self-attach freely; **agent-authored** acceptance tests → human approval (henhouse guard). All agent-created quests are visible and overridable in the cockpit; live gates are immutable to the executing agent; only the human attaches/detaches the hat.

---

## 9. Adapters

- **Linear / Notion / Slack** = **context sources** (read via existing MCP connectors) + a thin **status write-back** to `primary_ref`. Slack is notification + capture, not a tracker.
- **GitHub** = PR/CI status (display in Stage 1; gate inputs in Stage 2), via projdash's existing GraphQL reads.
- The quest store is the source of truth; adapters never own quest state.

---

## 10. CLI surface

```
quests                              # launch the cockpit (default)

quests session new [--agent claude] [--role solo|master] [--quest <id>]
quests session ls
quests session promote <id>         # headless → native tmux window
quests session demote <id>          # native → headless, drain inbox
quests session kill <id>

quests quest new                    # opens a planning session that authors a quest
quests quest edit <id>              # $EDITOR on the quest file (re-validated on save)
quests quest view <id>              # terminal summary (head + runtime)
quests quest diff <id> [--viewer …] # launch diff viewer on worktree-vs-base (default: scry; env-overridable)
quests quest open <id>              # open the HTML body in the browser
quests quest ls
quests quest dispatch <id> [--agent codex]   # send a session on the quest      (Stage 2+)
quests quest done <id>              # mark done (after gates pass / PR merged)
quests quest reconcile <id>         # planner re-reads body, proposes head fixes (later)
```

Editing binds only the executing agent's gates, never the user. A direction change mid-attempt = abort + restart (clean, or from current state); the approved spec is snapshotted at attempt launch.

---

## 11. Instance Isolation (day one)

Separate, independently-installable binary (`quests`), fully namespaced from current questmaster: own state root (`QUESTS_HOME`, env-overridable, e.g. `~/.quests-dev`), distinct socket/fifo paths, own tmux prefix, own branch/worktree naming. Both run; neither touches the other's state. The one collision risk — Claude Code's hooks config — is sidestepped: read each agent's `stream-json` from the supervised subprocess instead of relying on global hooks. `quests` is the **transitional name** for coexistence, not a permanent rebrand: on cutover the tool reclaims `questmaster`/`qm` (and optionally the internal namespaces, e.g. `~/.questmaster-state`) — but only *after* the old binary is retired, since reclaiming names while both run would recreate the collisions this isolation prevents. The cutover is housekeeping, not a port: Stage 1 already reaches free-session parity, so there's no feature migration and no durable state to move — just a rename plus repointed aliases/hooks. The name returns; the `session …`/`quest …` grammar stays. The real gate is that parity, not the effort.

---

## 12. Build Phases

### Stage 0 — validate (no code)
See §0. **Deliverable:** a go/no-go decision. **Gate:** must beat current-QM-plus-discipline.

### Stage 1 — the plan layer
*The original projdash + questmaster vision. Least risky: no headless rebuild, no loop.*

**Deliverables**
- Quest file format (HTML: visible JSON head + rich body), schema, and `quest-template.html`.
- `quest new/edit/view/open/ls` with **conformance validation** on save (refuse malformed; feed error back).
- Quest authoring through a **planning session** (interactive, tmux-hosted).
- **Cockpit**: three-pane TUI — agents roster (all repos, from hooks/state), quests list, detail pane with **open-in-browser** + **PR/CI status display** (read-only, via projdash queries).
- Instance isolation (§11). Free sessions behave exactly as questmaster today.

**Explicitly out:** gates execution, the loop, headless execution, agent-initiated quests.

**Acceptance**
- A free session spawns and is driven as fast as current questmaster (no regression).
- Authoring a quest produces a valid file; a malformed head is refused with a usable error.
- The cockpit shows every session across repos and each quest's PR/CI status; `quest open` renders the rich plan with a live status banner.
- The tool runs alongside current questmaster with zero shared state.

**De-risk first:** free-session parity (speed/fluidity) and whether the cockpit visibility genuinely replaces the manual HTML+index habit.

### Stage 2 — gates + the loop
*The agent-agnostic "iterate until green." Layered onto Stage 1 quests.*

**Deliverables**
- Gate catalog + runner (auto kinds: ci/pr/tests/typecheck/lint/coverage; toggle gates), with `before`-positioned barriers (a toggle/auto gate the loop won't cross until it passes; `before:"pr"` ⇒ loop owns PR creation).
- Loop controller (separate from the quest schema) with the async-gate state machine (§7).
- Headless supervisor + input channel; `quest dispatch` (send a session on a quest); cockpit detail-pane steer for headless sessions.
- `quest diff` — launch the configured diff viewer (default scry, swappable via flag/env) on the quest's worktree-vs-base, usable pre-PR.
- Router with mode-aware delivery + inbox (§6).
- Status write-back to `primary_ref`.

**Explicitly out:** unattended walk-away, agent-initiated quests, daemon, DAG.

**Acceptance**
- Dispatch a quest to codex/pi; it iterates to green on CI + tests without the user watching the TUI.
- The loop never closes a quest with a failing gate; failures inject and re-attempt; budget-out escalates.
- A toggle gate blocks completion until the user flips it.
- A `before:"pr"` review toggle holds the PR until the user reviews (via `quest diff`) and ticks it; the loop opens the PR only after.

**De-risk first (the #1 spike):** steer / live-view fidelity — prototype the headless detail view against a real session before committing.

### Stage 3 — autonomous
*The big, commodity, risky part. Only if Stages 1–2 earn it.*

**Deliverables**
- Unattended walk-away execution (process survives close; background dispatcher / daemon to pick up queued quests).
- Escalation round-trip (notify → reply → resume) end-to-end.
- Agent-initiated quests with trust-by-gate-type approval (§8).
- Sub-quest DAG (master spawns child quests; each own worktree/PR/gates).

**Acceptance**
- "Fix it and ship" runs implementation → green gates → merge unattended, escalating only on stuck/needs-toggle.
- An agent files a follow-up quest; externally-measured gates auto-run, agent-authored tests await approval.

---

## 13. Risks & Spikes

- **Steer / live-view fidelity (load-bearing, #1).** The cockpit's headless detail view must be rich enough that the user rarely promotes just to see what an agent is doing. If it feels like tailing logs, the headless model regresses vs tmux panes. Prototype against a real session before Stage 2 commits.
- **Free-session parity.** The free-session flow must be exactly as fast as `prefix+p` today, or the "subsumes questmaster" claim fails. Validate in Stage 1.
- **Gates verify what they assert, not what you meant.** Vacuous/green-but-wrong tests. Mitigate: TDD-before-impl ordering, coverage/mutation, the toggle catch-all.
- **Async-gate state machine.** Must suspend on slow CI / human PR-approval, not busy-wait. Define the attempt-complete signal.
- **Escalation UX.** Walk-away only works if the system can pull you back. Design the round-trip explicitly.
- **Build vs adopt.** The category ("harness engineering," PEV loops) is crowded — Archon, Symphony, Composio overlap heavily; the architecture is commodity. The edge is *personal fit* (terminal-first, plan-file-centered, tailored to exactly how you work), not a market gap. Re-check at each stage boundary whether adopting beats continuing to build.

---

## 14. Non-goals

- Not a Linear replacement — quests are *your plan layer*, complementary to the tracker.
- Not a programmable workflow engine (the Archon/babysitter direction) — a flat, opinionated quest with a fixed loop is the foil.
- No embedded terminal emulator in v1 — native + roster simultaneously needs tmux (kept) or that emulator (deferred Stage 3+).
- No central daemon until Stage 3.
```
