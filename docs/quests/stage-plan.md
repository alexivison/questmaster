# Quests — Stage 1.5 + Stage 2 Plan

Builds on merged Stage 1. Two shippable stages, plus a sketch of the deferred loop.

## Stage 1.5 — interactive board + picker attach

### Interactive detail pane

The detail pane gains internal focus, so you move between its interactive rows: the toggle gates and the related entries.

- **Toggle gates become checkable.** A toggle gate renders as `[ ]` / `[x]`; a key flips the focused one. Flipping mutates the quest, validates, writes the JSON, and rebuilds the HTML, reusing the same Save path the board's status moves (`a`/`w`/`d`) already use. This is the **human half of gate-state**: a toggle gate is met because you said so, which is authored, so it lives in the JSON.
- **Related entries open in place.** A key on a focused related entry opens its url with the OS opener. Since related is `{type,title,url}`, the type plus the url route it: Linear and GitHub to the browser, Slack handing off to its app. Read-only, no JSON change. Editing related (add/remove) stays in `qm quest edit`.
- Done stays a separate human stamp. Toggling gates is bookkeeping and visibility; you still mark the quest done yourself. An optional "all gates met" hint when every toggle is checked is a nice touch.

**Format addition:** toggle gates carry a `checked` bool (default false). The validator accepts it on `toggle` gates and forbids it on `auto` gates (auto results are observed, not authored; they live in the sidecar, see Stage 2). The renderers show toggle gates as checkboxes.

### Picker quest-selection

The interactive picker gains a quest-attachment step when creating a session: pick an active quest to attach (or none). Selecting one calls the attach-and-inject that Stage 1 already built (`session new --quest`), so this is a UI step over existing machinery. WIP and done quests are excluded from the selection, as everywhere.

## Stage 2 — manual gate-execution

### The gate model

The verifier is never the agent. **qm verifies the auto gates** by running their check and reading the result; **you verify the toggle gates** by checking the box; **the agent verifies nothing**, it only does the work. Evidence an agent surfaces can inform your judgment on a toggle, but it never passes a gate on its own.

Gates are a **checklist**, not a sequence: a quest is done when every gate is verified, in any order, autos green and toggles checked, and you stamp it. The only ordering is the `before: pr` barrier. There is no gate-to-gate pipeline.

### Running the checks

- **`cmd:<shell>` only.** qm runs the command in the session's worktree, exit zero passes, nonzero fails, output captured. It subsumes tests, typecheck, and lint as literal commands (`cmd:make test`, `cmd:npm run typecheck`). No `github:*` (async, needs a PR and the API), no `typecheck`/`lint`/`coverage` sugar, no repo-level config.
- **Repo-variance lives in the quest.** The check is the repo's real command, written into the quest at authoring time by the master or standalone, which is already sitting in that repo's worktree and reads the Makefile, package scripts, or CI to find the commands. (See the authoring-clause task.)
- **Trigger is manual.** A human-run `qm quest check <id>` (and a board key) runs the quest's auto gates, writes their results to the sidecar, and the detail pane then shows each auto gate as pass or fail beside the toggle checkboxes. No turn-end hook, no injection: those belong to the loop.

### Broken versus failed

A nonzero result splits in two and they must not be confused: the gate is legitimately unmet (the command ran, tests failed) versus the check itself is broken (typo, wrong command, not found). qm reads the exit code as the verdict and **flags non-execution distinctly** (a command-not-found or shell error reads as "misconfigured," not "the gate failed"), so a broken check announces itself rather than masquerading as a real failure. The first `qm quest check` you run, in the session's worktree, is the dry-run: you confirm each command runs to a verdict before relying on it, under your eye.

### Junk isolation

Checks run in the disposable per-session worktree, never the main checkout. Whatever a test command leaves behind dies with the session. qm fabricates nothing: no mock files, no scaffolding, no commits, only the command the quest authored.

### Results sidecar

Auto-gate results are observed and transient, so they live in a runtime sidecar in qm's dotfiles keyed by quest id (per gate: status pass/fail/error, last-run time, a captured-output snippet), **never in the quest JSON**. The detail pane merges the two homes: toggle state from the JSON, auto results from the sidecar. Done means all autos pass in the sidecar and all toggles are checked in the JSON.

## Stage 2-proper — the loop (sketch, deferred, not task-planned)

Not in this package. Recorded so it is not re-invented or coupled to headless.

- Native and supervised, in a visible tmux pane. **Explicitly armed**: a command or key puts one attached session into iterate-to-green mode, it is not automatic for every attached session.
- qm's turn-end hook signals a turn ended, qm runs the auto checks, and on failure `send-keys` injects the captured output back into the pane so the agent fixes it. Repeat until green or a stop condition.
- The loop only automates qm's verify-and-reinject of the auto gates. Toggle gates stay yours; the done stamp stays yours.
- **Non-goals:** headless execution; walk-away with the machine closed (that is a cloud-VM or remote deployment, not a qm mode). The "daemon" is only an event-driven listener for an armed session, lighter than a supervisor and in view.
- Open questions for when it is grilled: stop conditions (budget and stuck-detection), what exactly holds the armed-session listener, how `before: pr` gates the PR step.
