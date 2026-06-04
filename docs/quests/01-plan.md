# Quests in Questmaster — Reshaped Plan

Reshaped outcome of the grill: Quests is built **into questmaster**, not as a separate binary. No new CLI surface, no instance isolation, no headless substrate. We add a quest concept (plan + gates + status), a quest log, quest-aware spawning and attaching, and tracker integration. Gate execution and the loop stay deferred (Stage 2).

## The model

**Quest** = one HTML file: authored content plus a status. Lives at `~/.questmaster/quests/<id>.html`. Never in the repo, never committed.
- Authored content: goal, gates (the definition of done), plan body.
- Status (authored, human-owned): `wip` | `active` | `done`.

**Link** = a `quest_id` field on qm's `SessionState`.
- One active quest per session. Reassignable. Empty means a free / errand session.
- A quest can span a master+worker tree (all sessions carry its `quest_id`).
- "Sessions on quest X" is derived by scanning, never stored on the quest.

**Two independent axes:**
- Status (`wip`/`active`/`done`): authored in the file, human-set.
- Attached / running: derived from the session scan. Does not affect status.

**One fact, one home:**
- File = authored content + status.
- Session state = attachment (`quest_id`).
- Observed state (gate results, PR/CI) = deferred to a Stage-2 sidecar. Never in the file.

## Lifecycle (every status transition is the Questmaster's)

- **Created becomes `wip`.** Born WIP, authored by a master or standalone session.
- **`wip` to `active`.** You review and approve. Posts it to the board.
- **`active` to `done`.** You judge the gates met. Accepts the turn-in.
- The agent never sets status. It drafts content; you post and you close.

## Authoring

- A **master or standalone** session writes the quest content.
- Routed through qm (`qm quest new`), which owns the store and auto-generates the id. The agent never invents an id, writes the dotfile directly, or writes into the repo.
- **Validator** (`qm quest validate <id>`): checks the head against the schema (an `auto` gate requires a check; a `toggle` forbids one; required fields present; valid status). Refuse-malformed, feed the error back, the authoring session self-corrects until clean.
- Conformance is two layers: structure machine-checked (validator), meaning human-checked (your `wip` to `active` review).
- Result: a valid WIP quest awaiting your review.

## Attachment

- **Human-assigned.** Primary path: at spawn, `qm session new --quest <id>` stamps `quest_id` and seeds the opening prompt. Secondary: assign an active quest to an existing free session. Detach = clear the field, and the quest returns to the board.
- **Only `active` quests are attachable.** Spawn and attach menus list active quests only. WIP and done are excluded.
- Attaching shows in the log and the tracker but does not change status.
- Agent self-attach: deferred (Stage 2, gated).

## Prompt injects (two clauses in qm's existing inject layer)

- **Authoring clause** (master / standalone): how to create and write a conformant quest via qm, where it lives, that gates must be real checkable criteria, and to run the validator. You cannot post or close it.
- **Working clause** (session with a `quest_id`): qm hands the parsed goal, the gates as the definition of done, and the plan. Work to the gates. You cannot mark the quest done. Re-read the current quest with `qm quest view <id>`.

## Display

- **Quest log** = the standalone quests app, run in the rightmost shell pane of the qm layout. Shows all quests with status and a derived attached indicator. You check, edit, toggle, and approve here. WIP quests show but are marked / dimmed and cannot be selected for attach.
- **Tracker** = per session, its attached quest (id + goal + status badge), derived from `quest_id`.

## Storage

- Quests: `~/.questmaster/quests/<id>.html` (`<qm-home>` = `~/.questmaster`). qm owns the store.
- qm session state stays at `~/.questmaster-state`, gaining a `quest_id` on `SessionState`. (Authored quest docs and ephemeral session state are deliberately separate roots.)
- Worktree: inherited from the session's cwd for now. A formal quest-to-worktree binding is a Stage-2 concern (when gates check the artifact).

## Deferred to Stage 2 (not now)

- Gate execution and the iterate-to-green loop, built on the **native** substrate: qm's hook-based turn detection to know when a turn ends, `send-keys` to inject a failed gate back into the pane, and external checks (CI, test commands) for the gates themselves. Supervised, running in a visible tmux pane, not walk-away. Until then, gates are authored and read by eye.
- Agent self-attach and agent-writable status (gated).
- Runtime sidecar for observed state (gate results, PR/CI).

## Non-goals

- **Headless execution.** Dropped. Every session is a native TUI in tmux, in view at all times. The loop runs on native sessions, supervised.
- **Walk-away with the machine closed.** A native tmux session needs the machine awake. Unattended overnight runs, if ever wanted, are an always-on-machine deployment (a cloud VM, or the Claude Code remote pattern), not a headless mode built into qm.
