# Stage 1.5 + Stage 2 — task plan (T11–T17)

Continues Stage 1's numbering. Each task is a vertical slice ending with `go build ./...`, `go test ./...`, `go vet ./...` green. `[auto]` is machine-checkable; `[human]` is a review gate.

## Stage 1.5 — interactive board + picker attach

### T11 — Detail-pane interactivity: focus + toggle gates

**Scope.** Internal focus in the detail pane to move between interactive rows (toggle gates, related entries). Toggle gates render `[ ]` / `[x]`; a key flips the focused one. Add `checked` (bool, default false) to toggle gates in the format; the validator accepts it on `toggle`, forbids it on `auto`. Flipping reuses the existing validate-write-rebuild Save path (the one status moves use).
**Depends.** Stage 1 (format, store, board, renderers).
**Acceptance.** `[auto]` `checked` parses and validates on toggle only; renderer shows `[ ]`/`[x]`; flipping writes the JSON and rebuilds the HTML; no path sets `checked` on an auto gate. `[human]` toggling in the detail pane feels right.
**Non-goals.** auto-gate state, related editing, running checks.

### T12 — Related: open in place

**Scope.** With a related entry focused, a key opens its url via the OS opener (`open` / `xdg-open`). Type-aware where cheap (browser for linear/github, app handoff for slack via its url). Read-only, no JSON change.
**Depends.** T11 (focus model).
**Acceptance.** `[auto]` the opener is invoked with the focused entry's url; no JSON write occurs. `[human]` entries open in the right place.
**Non-goals.** adding or removing related entries (stays in `qm quest edit`), deep-link schemes.

### T13 — Picker quest-selection

**Scope.** The interactive picker gains a quest-attachment step on session creation: choose an active quest or none. Selecting calls the existing `session new --quest` attach-and-inject. WIP and done are excluded from the choices.
**Depends.** Stage 1 (spawn/attach, store).
**Acceptance.** `[auto]` selecting an active quest stamps `quest_id` and seeds the working brief; wip and done never appear as choices; "none" spawns a free session. `[human]` the picker flow feels right.
**Non-goals.** changing non-quest picker behavior.

## Stage 2 — manual gate-execution

### T14 — Gate runner (`cmd:` execution)

**Scope.** Run a `cmd:<shell>` check in a given worktree, capture exit code, stdout, and stderr, and classify the result as `pass` (exit 0), `fail` (ran, nonzero), or `error` (did not execute: command-not-found, shell error, nonzero with no usable output). The worktree is the run directory. Pure enough to test with crafted commands.
**Depends.** Stage 1 (gate types).
**Acceptance.** `[auto]` exit 0 → pass; nonzero with output → fail; a missing command → error/misconfigured, not fail; output is captured; the run cwd is the passed worktree; no files are created by the runner itself.
**Non-goals.** the trigger, the sidecar, `github:*`, injection.

### T15 — Results sidecar

**Scope.** A runtime store in qm's dotfiles keyed by quest id holding the latest auto-gate results (per gate: status, last-run time, captured-output snippet). Never written into the quest JSON, never into a repo. The detail-pane render merges sidecar auto results with JSON toggle state.
**Depends.** T11 (render), T14 (result shape).
**Acceptance.** `[auto]` write then read round-trips results; the detail pane shows autos as pass/fail/error from the sidecar and toggles as `[ ]`/`[x]` from the JSON; the sidecar path is under qm's dotfiles, asserted not under a repo; the quest JSON is never mutated by a check run.
**Non-goals.** the trigger UI, the loop.

### T16 — `qm quest check` + board key

**Scope.** `qm quest check <id>` (and a board key) runs the quest's auto gates via T14 in the attached session's worktree, writes results via T15, and surfaces them in the detail pane. Broken checks are reported as misconfigured, not injected anywhere and not counted as a real fail. This run is the manual dry-run.
**Depends.** T14, T15, plus a way to resolve the quest's worktree (the attached session).
**Acceptance.** `[auto]` check runs all auto gates, writes the sidecar, returns per-gate status; an error result is labeled misconfigured distinctly from fail; runs in the session worktree, not the main checkout. `[human]` the first run reads clearly: executed-and-failing versus misconfigured.
**Non-goals.** turn-end triggering, failure injection, arming (all the loop).

### T17 — Authoring clause: repo-real commands

**Scope.** Extend the authoring inject so the master or standalone writing a quest fills each `cmd:` check with the repo's real command, discovered by reading the Makefile, package scripts, or CI in the worktree it is already in.
**Depends.** Stage 1 (injects).
**Acceptance.** `[auto]` the authoring clause contains the instruction to discover and write real commands. `[human]` newly authored quests carry runnable `cmd:` checks for their repo.
**Non-goals.** repo-level config, command inference by qm.

## Done

All `[auto]` green across T11–T17; the `[human]` gates reviewed. On the board you can toggle manual gates and open related links from the detail pane; the picker attaches a quest on spawn; `qm quest check` runs the auto gates in the disposable worktree and reports pass / fail / misconfigured into the sidecar and the detail pane; and the agent still verifies nothing. The autonomous loop is the remaining Stage 2 work, sketched in `stage-plan.md`, to be grilled and task-planned when wanted.

## Non-goals across this package

The loop (turn-end hook, failure injection, arming), headless, walk-away, `github:*` checks, `typecheck`/`lint`/`coverage` sugar, repo-level config, agent-set status, agent gate-passing.
