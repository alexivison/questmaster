# Quests in Questmaster — Stage 1.5 + Stage 2 Handoff

You are extending **Quests inside questmaster**, on top of merged Stage 1 (PR #36). Stage 1 shipped the quest format, the JSON-source model, the renderers, the store, spawn/attach, the injects, the board, and the tracker line. This package adds two things, both shippable on their own:

- **Stage 1.5** — make the board interactive: toggle the manual gates and open related links from the detail pane, and let the picker attach a quest on spawn.
- **Stage 2 (manual gate-execution)** — make the auto gates actually run. qm executes `cmd:` checks and reports pass or fail. No autonomous loop yet.

## Read in this order

1. `stage-plan.md` — the design decision record for both stages, including the format additions. Read it fully first.
2. `stage-tasks.md` — the numbered slices (T11 through T17), in order. Your worklist.

The quest format spec from Stage 1 lives in the repo at `docs/quests/quest-format.md`. This package extends it (a `checked` field on toggle gates, a results sidecar); the additions are in `stage-plan.md`.

## Prime directives (these override convenience)

1. **Build into qm.** No new binary. New surface is `qm quest check`, the picker quest step, and detail-pane keys.
2. **No headless, and do not build the loop.** The autonomous gate-loop (turn-end hook, failure injection, arming) is *sketched* in `stage-plan.md` under Stage 2-proper and is **not** in scope here. Do not build it.
3. **The verifier is never the agent.** qm runs the auto checks and holds the verdict; the human checks the toggle gates; the human stamps done. No code path may let an executing agent pass a gate, set a gate's state, or set status.
4. **Checks run in the session's disposable worktree, never the main checkout.** qm fabricates nothing: it runs the command the quest authored and reads exit code plus output. No mock files, no scaffolding, no commits.
5. **`cmd:` only.** No `github:*` checks, no `typecheck`/`lint`/`coverage` sugar, no repo-level config.
6. **Verifiability.** `go build ./...`, `go test ./...`, `go vet ./...` green at the end of every task.
7. **Only active quests are attachable.**
8. **Mine qm and scry for conventions** (keymaps, TUI patterns, worktree handling, the existing Save/validate/rebuild path). On real ambiguity, stop and leave a note rather than inventing.

## Where to stop and surface

Human-judgment gates, build up to them then surface a working build:
- The detail-pane interaction feels right: toggling gates, opening related (T11, T12).
- The picker quest step feels right (T13).
- The first `qm quest check` run reads clearly: executed-and-failing versus misconfigured (T16).

## Pushing

Belongs in the qm repo at `docs/quests/`. Commit and push to the branch the implementation runs from so a remote clone sees it.
