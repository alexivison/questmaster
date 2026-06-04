# Quests in Questmaster — Stage 2-proper (the loop) Handoff

You are building the **autonomous gate-loop**, on top of Stage 2 manual
gate-execution (T14–T17). Stage 2 made qm the verifier of auto gates: a
human-run `qm quest check` runs a quest's `cmd:` checks in the attached session's
worktree and records pass / fail / misconfigured. This stage closes that manual
trigger into a supervised loop — qm watches for the turn to end, runs the autos
itself, and on a real failure re-injects the captured output so the agent fixes
the work, repeating until green or a stop condition.

The loop automates **only** qm's verify-and-reinject of the auto gates. Toggle
gates stay the human's, status stays human-only, the done-stamp stays human.

## Read in this order

1. `loop-plan.md` — the design-decision record. Read it fully first. The key
   facts: the turn-end signal already lands on disk (no new hook), checks cannot
   run in the hook hot-path (so a listener does the work), and the listener is a
   **foreground `qm quest loop <session>` command in a visible pane** — arming is
   running it, disarm is Ctrl-C or a stop condition.
2. `loop-tasks.md` — the numbered slices T18–T23, in order. Your worklist.

The Stage 1 quest-format spec is at `quest-format.md`; the Stage 1.5 + 2 record
is in `stage-plan.md` (its final section sketches this loop — `loop-plan.md`
supersedes that sketch).

## Prime directives (these override convenience)

1. **Build into qm.** New surface is `qm quest loop`, an arming indicator, and a
   sandbox `loop` subcommand. No new binary, no daemon, no headless.
2. **The verifier is never the agent.** Inject auto-gate *failures* (the work is
   wrong); never tell the agent to pass a gate, set a gate, or set status.
   Misconfigured checks pause for the human. Toggles and the done-stamp stay
   human.
3. **Checks run in the attached session's disposable worktree, never main.**
   `cmd:` only. No `github:*`, no typecheck/lint/coverage sugar.
4. **Explicitly armed, supervised, in view.** A foreground command in a pane;
   arming is running it; disarm is Ctrl-C or a stop condition.
5. **Reuse, don't rebuild.** The turn-end signal (the existing `done` state
   write), the gate runner (`gate.RunCheck`), the relay (`message.Service.Relay`),
   and the link/worktree resolution. No new hook, no installer change.
6. **Stop conditions are mandatory.** Budget + stuck-detection + blocked-pause so
   an armed loop always terminates and hands back.
7. **Verifiability.** `go build ./...`, `go test ./...`, `go vet ./...` green at
   the end of every task.
8. **Mine qm and scry for conventions** — cobra command factories, the message
   relay, the flock read-modify-write, the sandbox harness, golden + table tests.
   On real ambiguity, stop and leave a note rather than inventing.

## Where to stop and surface

Build up to these human-judgment gates, then surface a working build:

- The armed loop reads clearly in the pane: a real fail → the injected output →
  the agent fixing → green, and a *misconfigured* check pauses with a clear
  message rather than nagging the agent (T20, T21).
- It always terminates: budget and stuck-detection hand back; Ctrl-C disarms
  instantly (T23).
- The arming indicator is legible in the tracker/board (T22).

## Pushing

Belongs in the qm repo at `docs/quests/`. Commit and push to the branch the
implementation runs from so a remote clone sees it.
