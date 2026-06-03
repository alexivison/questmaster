# Quests — Stage 2-proper: the autonomous gate-loop (design)

Builds on **Stage 2 manual gate-execution** (T14–T17, in PR #36). That stage made
qm the verifier of auto gates: `qm quest check` runs a quest's `cmd:` checks in
the attached session's worktree, classifies pass / fail / misconfigured, and
writes the sidecar. This stage closes the manual trigger into a supervised loop:
qm watches for the turn to end, runs the autos itself, and on a real failure
re-injects the captured output so the agent fixes the work — repeating until
green or a stop condition. It is the design-decision record for that loop.

The loop only ever automates **qm's verify-and-reinject of the auto gates.**
Toggle gates stay yours, status stays human-only, the done-stamp stays yours.

## The realisation that shapes the design

Almost nothing new has to be built; the loop is a small orchestrator over parts
that already exist:

- **The turn-end signal already lands on disk.** Claude's `Stop` hook fires
  `questmaster hook claude done` (Codex `done`, Pi `agent_end`), and the handler
  writes `pane.State = "done"` into `<state_root>/<id>/state.json`
  (`cmd/hook.go`, `internal/hooks/claude.go`). A turn ending is therefore already
  observable. **The loop adds no new hook and no installer change.**
- **The verify half is Stage 2.** `gate.RunCheck(name, check, worktree)` returns
  `{Status: pass|fail|error, Output}` where `error` is a broken/misconfigured
  check, kept distinct from a real `fail` (`internal/quests/gate/run.go`).
- **The inject half is the relay path.** `message.Service.Relay(ctx, sessionID,
  text)` resolves the primary pane and delivers the prompt. Multiline failure
  prompts use the existing relay-file indirection, so the pane receives the
  standard "read this file" instruction and the file body is the golden-tested
  loop prompt.
- **The link and the worktree are Stage 1/2.** `state.QuestIDForSession` resolves
  the quest on the requested session; the worktree is that session's
  `manifest.Cwd`. Checks run there, never in the main checkout.

## The one hard constraint

The hook hot-path **must not run checks.** It is a `<20 ms` path that "must never
call methods that scan the state root" (`cmd/hook.go`). So the auto gates cannot
run synchronously inside the turn-end hook. Something else has to watch for the
`done` edge and do the work. That "something" is the listener — and *what holds
the listener* was the central open question in the original sketch.

## The listener: a foreground command in a visible pane

A blocking command, run in a visible tmux pane:

```
qm quest loop <session>
```

- **Arming is running it.** There is no daemon, no PID file, no background
  supervision to crash-recover. The process *is* the armed state, in view, under
  your eye — matching the sketch's "native and supervised, in a visible tmux
  pane … lighter than a supervisor."
- **Disarming is Ctrl-C** (or any stop condition firing). One keystroke ends it.
- It tails the session's `state.json` for **done-edges**, runs the quest's autos
  in the worktree, prints each iteration's verdict, and injects on failure.
- An **advisory marker** is written to `SessionState` while it runs
  (`quest_loop`), used only so the tracker/board can *show* that a session is
  iterating and so a second `loop` on the same session refuses. The marker is
  not load-bearing — the foreground process is the source of truth — and is
  cleared on exit (a stale marker after a crash is cleared by `--force` or a
  re-attach).
- The shipped flags are `--max-iters`, `--max-time`, `--stuck-after`, and
  `--force`.

Explicitly **out**: a background daemon, arming every attached session
automatically, headless execution, walk-away with the machine closed (that is a
cloud/remote deployment, not a qm mode).

## The cycle

```
[turn ends] ── existing hook writes state.json: state=done, new Seq
      │
  watcher sees the done-edge
      │
  run the quest's auto gates in the attached worktree   (gate.RunCheck)
      │
      ├─ all autos pass ............ STOP: green. You still check toggles + stamp done.
      ├─ a real fail (exit nonzero)  INJECT the failed gate(s) + output snippet
      │                              with a "fix the work" directive → agent works
      │                              → next done-edge → re-check. (the loop)
      ├─ misconfigured (127/126/     PAUSE + surface to you. Never injected as a
      │   bad cmd / non-cmd:)        failure — a broken check is a quest-authoring
      │                              bug, not the agent's to chase.
      ├─ agent went blocked          PAUSE. A permission/question prompt needs you;
      │   (state=blocked)            the loop does not inject over a human prompt.
      └─ budget hit / stuck          STOP + hand back with the last verdict.
```

### Outcomes, precisely

- **green** — every auto gate is `pass`. The loop stops successfully. It does
  **not** stamp the quest done and does **not** check toggle gates; those stay
  yours. It prints "all autos green — yours to verify + stamp."
- **fail** — at least one auto gate is `fail` (and none are `error`). The loop
  injects (see below) and waits for the next done-edge.
- **misconfigured** — at least one auto gate is `error`. The loop pauses and
  surfaces the broken check to the console; it injects nothing. Rationale: the
  verifier is never the agent, and a misconfigured check is a typo in the quest,
  which is yours (or the authoring master's) to fix, not the running agent's.
- **blocked** — the watcher sees `state=blocked` (permission/AskUserQuestion/Pi
  waiting). The loop pauses; injecting over a human prompt would be wrong. It
  resumes watching once the agent returns to a done-edge, or stops with
  `blocked_timeout` if it remains blocked past the internal timeout.
- **stop** — a stop condition fired (budget or stuck); the loop ends and prints
  the stop reason plus the last verdict so you can take over.

## The injection (the highest-judgment surface)

On a real failure the loop relays a bounded, structured message to the primary
pane:

- **What failed:** the failing auto gate name(s).
- **The evidence:** a truncated snippet of the captured `Output` (head+tail,
  capped — the relay is a prompt, not a log dump).
- **The directive:** *fix the work so the check passes* — never *pass the gate*,
  never *mark it done*. The agent fixes the code; qm re-runs the check and holds
  the verdict. The message states plainly that qm ran the check and will re-run
  it, so the agent does not try to self-verify or edit the quest.

The exact wording is golden-tested (it is the part most likely to drift), and is
apostrophe-safe if it is ever embedded in a shell-quoted context (the same
lesson as the authoring/working clauses). Because the prompt is multiline, the
existing relay layer normally sends a pointer to a temp file; the prompt body in
that file is what is golden-tested.

Misconfigured checks are **not** injected. The console surfaces them: "gate
`<name>` is misconfigured (`<reason>`) — fix the quest's check; not injected."

## Stop conditions (mandatory — an armed loop must always terminate)

1. **Green** — all autos pass. Success.
2. **Budget** — `--max-iters N` (default e.g. 6) and `--max-time D` (default e.g.
   20m). Either ceiling stops the loop.
3. **Stuck** — the same failure signature (failing-gate set + a hash of the
   output snippet) repeats `--stuck-after K` times in a row (default e.g. 3),
   meaning the agent is not making progress. Stop and hand back.
4. **Blocked-pause** — not immediately terminal; the loop holds rather than
   injecting. If it stays blocked past the internal timeout, it stops with
   `blocked_timeout` and hands back.
5. **Human** — Ctrl-C disarms immediately.

Every stop prints the reason and the last per-gate verdict (`last verdict: none`
when no check has run yet).

## `before: pr` and the PR step

The loop's definition of "green" is exactly **all auto gates pass.** It does not
open PRs and runs no `github:*` checks (none exist this stage). The `before: pr`
barrier stays informational: it tells *you* which gates must be green before you
open the PR and stamp the quest. The loop simply drives the autos to green; the
PR and the done-stamp remain your manual steps.

## Concurrency and worktree safety

The loop runs checks only on a **done-edge**, i.e. when the agent is idle, so a
`cmd:make test` never races a half-applied edit. Checks run in the disposable
per-session worktree; whatever a test leaves behind dies with the session. qm
fabricates nothing — only the command the quest authored, exactly as Stage 2.
The done-edge is detected by a strictly-increasing `Seq`/`LastEvent` with
`State=="done"`, so each turn end is processed once.

## Format / state additions

- **`SessionState.QuestLoop`** (advisory): `{ since, iterations, last_verdict }`,
  written while `qm quest loop` runs, cleared on exit. Read by the tracker/board
  to show an "iterating" indicator and to refuse a double-arm. The tracker shows
  `↻ loop i<N> <verdict>` next to the quest line; the board shows the same loop
  label in the selected quest detail/footer. Preserved across hook writes the
  same way `QuestID` is (whole-struct RMW under flock).
- **No change** to the quest JSON, the gate model, the sidecar shape, or the
  installed hooks.

## Sandbox

`scripts/quests-sandbox.sh loop` runs an isolated end-to-end loop demo. It uses
scratch `QUESTMASTER_HOME` / `QUESTMASTER_STATE_ROOT`, a stub `tmux`, a fake
attached session, and a fake agent that creates the file needed by the check
after the first injected failure. The run deterministically shows:

```
iteration 1: fail
...
iteration 2: green
terminal: all autos green — yours to verify + stamp.
```

It also prints the injected prompt body and final sidecar so the loop can be
checked without touching real sessions or real quest state.

## Prime directives (these override convenience)

1. **Build into qm.** New surface is `qm quest loop`, the arming indicator, and a
   sandbox `loop` subcommand. No new binary, no daemon.
2. **The verifier is never the agent.** The loop injects auto-gate *failures*
   (the work is wrong); it never tells the agent to pass a gate, set a gate, or
   set status. Misconfigured checks pause for you. Toggles and the done-stamp
   stay human.
3. **Checks run in the attached session's disposable worktree, never main.**
   `cmd:` only. No `github:*`, no typecheck/lint/coverage sugar.
4. **Explicitly armed, supervised, in view.** A foreground command in a pane;
   arming is running it; disarm is Ctrl-C or a stop condition. No headless, no
   walk-away.
5. **Reuse, don't rebuild.** The turn-end signal (the existing `done` state
   write), the gate runner, the relay path, the link/worktree resolution. No new
   hook, no installer change.
6. **Stop conditions are mandatory.** Budget + stuck-detection + blocked-pause so
   an armed loop always terminates and hands back.
7. **Verifiability.** `go build ./...`, `go test ./...`, `go vet ./...` green at
   the end of every task.
8. **Mine qm for conventions** — cobra command factories, the message relay, the
   flock read-modify-write, the sandbox harness, golden + table tests. On real
   ambiguity, stop and leave a note rather than inventing.

## Non-goals (recorded so they are not re-invented)

Headless execution; walk-away with the machine closed; a background daemon;
`github:*` checks; `typecheck`/`lint`/`coverage` sugar; agent-set status or
agent gate-passing; auto-stamping done; auto-opening PRs; orchestrating more than
one armed session at a time (one session per `qm quest loop`).
