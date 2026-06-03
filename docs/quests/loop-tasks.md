# Quests — Stage 2-proper: the loop (tasks)

The numbered worklist for the autonomous gate-loop. Read `loop-plan.md` first;
it is the design-decision record these slices implement. Continues the quest
T-numbering from Stage 2 (which ended at T17). Each task ends green on
`go build ./...`, `go test ./...`, `go vet ./...`.

Order matters: the pure engine first (T18), then the watcher (T19), then the
command that wires them with the real gate-runner and relay (T20), then the
injection surface (T21), then visibility (T22), then stop-condition polish +
sandbox + docs (T23).

---

## T18 — Loop engine (pure core)

A new package `internal/quests/loop` with a pure, dependency-free engine that
drives the cycle from injected collaborators. No tmux, no filesystem, no clock
of its own.

- **Inputs (interfaces / func fields):** a `CheckRunner` that returns the autos'
  `[]gate.Result` for one iteration, an `Injector` that delivers a failure
  message, a `Clock`, and a source of turn-end / blocked signals (a channel or a
  `Next()` call so tests can feed a scripted sequence).
- **Outcome classification** per iteration from `[]gate.Result`:
  `green` (all pass) · `fail` (≥1 fail, 0 error) · `misconfigured` (≥1 error).
  Plus loop-level outcomes: `blocked`, `stopped(reason)`.
- **Stop config:** `MaxIters`, `MaxWall`, `StuckAfter`, `BlockedTimeout`.
- **Stuck detection:** hash the failure signature (sorted failing-gate names +
  output-snippet hash); `StuckAfter` identical signatures in a row → stop.
- **No side effects beyond the injected `Injector`.** The engine never touches
  the quest, the sidecar, status, or toggles.

**Verify:** table tests over scripted check sequences — `fail,fail,pass` → two
injects then green; a single `error` → `misconfigured` pause, zero injects;
`fail` with an unchanging signature ×`StuckAfter` → `stopped(stuck)`; iterations
past `MaxIters` → `stopped(budget)`; a `blocked` signal → pause, no inject.

## T19 — Turn-end watcher

Watch one session's `state.json` for **done-edges** and surface them to the
engine. Decoupled from the engine and the command.

- Poll-based (simple, dependency-free) at a small interval; emit a turn-end event
  when the primary pane reaches `State=="done"` with a strictly-increasing
  `Seq`/`LastEvent` not yet processed (so each turn end fires once).
- Emit a `blocked` event when `State=="blocked"` so the engine can pause.
- Resilient to a missing/cold state file (waits), and to schema-foreign state
  (ignores, like the tracker).

**Verify:** drive a temp `state.json` through working→done→working→done cycles
and assert exactly one turn-end event per `done` edge; a `blocked` write emits a
blocked event; repeated identical `done` writes (same Seq) emit nothing.

## T20 — `qm quest loop <session>` (the armed runner)

The foreground command that wires watcher + engine with the real collaborators.

- Resolve the quest from the session (`state.QuestIDForSession`); require it
  **active** and **attached** with a worktree (`questWorktree`) — reuse the
  Stage 2 resolution and its errors. Refuse otherwise with a clear message.
- `CheckRunner` = run the quest's auto gates in the worktree (the existing
  `runQuestCheck` core, factored so the loop and `qm quest check` share it) and
  also write the sidecar each iteration so `quest view`/board reflect live
  verdicts.
- `Injector` = `message.Service.Relay` to the session's primary pane.
- Blocking + supervised: print a header, each iteration's per-gate verdict, and
  the terminal outcome; Ctrl-C (context cancel) disarms cleanly.
- Write the advisory `SessionState.QuestLoop` marker on start, clear it on exit
  (deferred); refuse a second concurrent arm on the same session unless
  `--force` (which also clears a stale marker).
- Flags: `--max-iters`, `--max-time`, `--stuck-after`, `--force` (sensible
  defaults from the plan).

**Verify:** command tests with a stub tmux runner and a scripted state file —
an unattached/non-active quest is refused; a session that fails-then-passes runs
the expected number of injects and exits green; the marker is set during and
cleared after; a misconfigured gate pauses without injecting.

## T21 — Injection message + misconfigured surface

The exact text the loop injects, and how a misconfigured check is surfaced — the
highest-judgment piece, so it gets its own slice and a golden test.

- Failure message: failing gate name(s) + a head+tail-truncated output snippet +
  a directive to *fix the work so the check passes* (never "pass the gate", never
  "mark it done"), stating that qm ran the check and will re-run it.
- Apostrophe-safe and bounded (a prompt, not a log).
- Misconfigured console line: `gate <name> misconfigured (<reason>) — fix the
  quest's check; not injected`.

**Verify:** golden test of the rendered injection for a representative failure;
an assertion that the message contains the gate name + a bounded snippet and does
**not** contain any "pass/approve/mark done" phrasing; a test that a
misconfigured result produces the console surface and zero injections.

## T22 — Arming visibility

Show that a session/quest is iterating, reading the advisory marker.

- Tracker: an "iterating" indicator on the armed session's row (near the quest
  line), consistent with the existing quest-line styling.
- Board: the armed quest's detail/footer notes it is in loop mode.
- No new scan cost on the hot path — read the marker already on `SessionState`.

**Verify:** renderer/board tests that a marker present → the indicator shows, and
absent → it does not.

## T23 — Stop conditions polish, sandbox, and docs

Make the loop safe to run for real and testable in isolation.

- Confirm budget + stuck + blocked-timeout all terminate and print the reason +
  last verdict (covered by T18 tests; here wire the flags end-to-end).
- `scripts/quests-sandbox.sh loop`: a fully isolated end-to-end harness (scratch
  `QUESTMASTER_HOME`/`QUESTMASTER_STATE_ROOT`, stub tmux) with a fake "agent"
  that flips the state file working→done and "fixes" the check on the 2nd turn,
  so you can watch a fail → injected output → green run without a real agent.
- Promote/trim this doc set: fold anything that changed during implementation
  back into `loop-plan.md`; mark resolved open questions.

**Verify:** the sandbox `loop` run reaches green deterministically; build/test/vet
green; docs match the shipped behaviour.

---

## Where to stop and surface (human-judgment gates)

Build up to these, then surface a working build for a human eye:

- **The armed loop reads clearly in the pane** (T20/T21): you can watch a real
  fail → the injected output → the agent fixing → green, and a *misconfigured*
  check **pauses with a clear message** rather than nagging the agent.
- **It always terminates** (T23): budget and stuck-detection hand back instead of
  spinning; Ctrl-C disarms instantly.
- **The arming indicator is legible** in the tracker/board (T22).
