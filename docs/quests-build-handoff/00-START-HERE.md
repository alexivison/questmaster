# Quests — Build Handoff

You are building **Quests**, an evolution of the existing `questmaster` repo, as a **second binary in that same repo** (`cmd/quests`), sharing the `internal/` spine, with fully isolated runtime state. The current `questmaster` binary stays frozen and must keep working.

**Your build target is Stage 1 only.** Do not build Stage 2/3 work.

## Read in this order

1. **`01-build-spec.md`** — the full-vision spec (the *why* and *what*). Reference; not all of it is this stage.
2. **`02-skeleton.md`** — the **fixed structural contract**: module/binary layout, package tree, and the load-bearing types/interfaces. **Do not redesign any of this.** Packages tagged *seam — do not build* are off-limits.
3. **`03-stage-1-plan.md`** — the numbered tasks to execute now, in order. This is your worklist.

Supporting material (rationale / reference, read as needed):
- `design-log.html` — how every decision was reached.
- `relations.html` — the architecture relations (sessions = substrate, quest = optional hat).
- `cockpit-layout.html` — the target three-pane TUI.
- `quest-template-example.html` — the canonical shape of a quest file (your parser/validator must accept this; ship a copy as `quest-template.html`).

## Prime directives (these override convenience)

1. **Verifiability is the gate.** `go build ./...`, `go test ./...`, `go vet ./...` must be green at the end of **every** task. A task that doesn't build and pass is not done.
2. **Vertical slices.** Each task leaves the tree compiling and tested. No half-wired packages spanning a task boundary.
3. **Stay in stage.** If the obvious next step lands in a `seam — do not build` package (`gate`, `loop`, `supervisor`, `router`), **stop** — that boundary is a hard gate.
4. **On ambiguity, stop and flag.** Follow an existing questmaster convention if one fits; otherwise leave a note in the task and stop, rather than guessing. Unattended ≠ free to invent.
5. **Don't break questmaster.** `cmd/questmaster` behavior is frozen; its existing tests are the guardrail for any spine refactor.
6. **Quests live in dotfiles, not source.** The finished tool writes quest files to `~/.quests/quests/<id>.html` — never into a repo, never committed. (This handoff folder is the exception: it's *input* and belongs in the repo.)

## Where to stop and surface

Two Stage 1 acceptance criteria are **human-judgment gates**, not automatable — they are your check-in points, not things to self-certify:
- **Free-session parity** (Task 8): does spawning/driving a free session feel as fast and fluid as `prefix+p` in questmaster today?
- **Cockpit replaces the habit** (Task 7): does the cockpit actually stand in for the manual HTML-plan + index workflow?

Build everything up to these autonomously; when you reach them, surface a working build for review rather than declaring done.
