# Quests — Stage 1 build notes

Running log of decisions made while executing `docs/quests-build-handoff/03-stage-1-plan.md`.
Per the handoff prime directive *"on ambiguity, stop and flag"*, anything where a
judgement call was made (rather than following an existing questmaster convention
verbatim) is recorded here so it can be vetoed at the human-judgment gates (T7/T8).

## T0 — spine parameterization + `cmd/quests` skeleton

- **Two binaries.** The existing `questmaster` binary keeps its entrypoint at the repo
  root (`main.go` → `package cmd`); it is *not* relocated to `cmd/questmaster/` (the
  skeleton's tree is the post-cutover target, not a Stage-1 move — relocating it risks
  the frozen binary). The new binary lives at `cmd/quests/` (`package main`), so
  `go install ./cmd/quests` builds only Quests, and `go build ./...` builds both.

- **Namespace = state-root injection (existing convention).** The `state` package is
  *already* parameterized on its root: `state.OpenStore(root)` / `state.NewStore(root)`
  take it directly, and the `QUESTMASTER_STATE_ROOT` env var overrides the
  `~/.questmaster-state` default (this is the same mechanism questmaster's own tests use
  to isolate state). Quests injects its own root — `<QUESTS_HOME>/state`, default
  `~/.quests/state` — by (a) constructing its stores with that root and (b) exporting
  `QUESTMASTER_STATE_ROOT` to it at startup so the agent-hook propagation path
  (`session/launch.go`, `session/start.go`) and the package-level `state` helpers resolve
  to the quests namespace. No destructive refactor of `state` was needed; questmaster
  keeps its default untouched.

- **Session-ID / tmux-name prefix kept as `qm-` in Stage 1 (flagged).** The skeleton lists
  "own tmux prefix / branch naming" for Quests, and `Paths` carries `TmuxPrefix:"quests"` /
  `BranchPrefix:"quest/"`. However, re-parameterizing the session-ID prefix means threading
  a value through `state.IsValidSessionID` (its `^qm-` regex is consumed by 17 files, all on
  frozen questmaster paths) — invasive, not required by any T0 acceptance check, and a real
  risk to the "don't break questmaster" guardrail. **Decision:** functional isolation in
  Stage 1 is provided by the *distinct state root* (each tool's roster/state reads only its
  own root, so neither sees the other's sessions); the `TmuxPrefix`/`BranchPrefix` values are
  carried for Quests-owned naming (cockpit labels, Stage 2+ worktree/branch creation) and for
  the eventual `questmaster` name reclaim at cutover (build-spec §11). The residual is that
  raw `tmux ls` shows both tools' sessions under the `qm-` prefix; they still cannot collide
  in state. Surfaced here for veto at the T7/T8 gate.

## T2 — quest head parsing

- **In-string whitespace normalization.** The canonical `quest-template-example.html` wraps
  the `goal` value across two source lines for readability, so the `#quest-head` text content
  contains a literal newline + indentation *inside* a JSON string — which strict
  `encoding/json` (and browser `JSON.parse`) reject. `Parse` therefore normalizes runs of raw
  whitespace that occur inside string literals down to a single space before decoding. This is
  what makes the canonical template parse, as the handoff requires.
