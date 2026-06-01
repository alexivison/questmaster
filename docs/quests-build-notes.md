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

## T7/T8 revision — cockpit rework from local-testing feedback

Reworked the cockpit after the first human-gate review:
- **Layout matches the mock.** Pane ratios are now ~22% / rest / ~36% (agents is the
  *smallest* pane). The detail pane is **hidden by default** ("scan mode") and opens on
  `Enter`/focus, toggled off with `Esc` — per the user's "right pane closed by default".
- **Agents pane = the tracker.** Roster is grouped **by repo** (first-appearance / mtime
  order, not alphabetical), renders the tracker glyph vocabulary (`◐`working `●`done
  `!`blocked `○`idle), shows role, **nests workers** under their master (`└ impl`), and
  shows live activity text — built from the manifest tree (parent_session/workers) +
  per-session SessionState.
- **Spawn from the cockpit.** `a` authors a new quest (textinput) → creates the scaffold
  + spawns a master planning session; `n` spawns a free session. Both attach via the
  Jump path. `tea.ExecProcess` relinquishes the terminal for attach/diff/edit.
- **Jump to sessions.** `Enter`/`g` on a roster session → `tmux switch-client` (in tmux)
  / `attach` (outside) — the "one switcher" jump.
- **prefix+p parity.** Added `quests picker` (the questmaster picker reused under the
  Quests namespace) and `quests session new --attach`, so a tmux binding gives the same
  fast spawn/jump.

## T7/T8 revision 2 — split agents tracker / quests dashboard, real-time, system brief

Second round of gate feedback (with the questmaster tracker screenshot as the source
of truth):
- **Agents = the real tracker, reused.** `quests agents` launches `tui.LaunchAgents`
  (new exported helper) — the actual questmaster tracker (`LiveSessionFetcher` already
  does `DiscoverSessions`), so it's identical: agent icons, italic activity snippet,
  `✱ id  □ cwd`, nested workers, configurable display-color bars, 3s poll, question/blocked
  states, and jump-on-Enter. No reimplementation. It tolerates no-current-session so it
  runs standalone as well as in-session.
- **Sidebar = agents tracker.** `resolveQuestsCmd` now launches `quests agents`, so jumping
  into a session shows only the tracker, not the whole dashboard.
- **Dashboard (`quests`) is quests-only and never navigates away.** It dropped the agents
  roster, jump, and the `g` key (jump now lives in the tracker). It is live-polled (2s) so
  the quests list + runtime refresh in real time. `o`/`d`/`e` use `tea.ExecProcess` and
  return to the dashboard when the viewer/editor closes — so there's always a way back.
- **Quest-awareness via system prompt (replaces the author flow).** `quest.SystemBrief()`
  teaches any spawned session about the quest format + the `quests quest` CLI; it's injected
  as `StartOpts.SystemBrief` for every quests-spawned session. So a plain free session is
  quest-aware and the user can just talk about creating quests — the clunky cockpit "author"
  input was removed.

## Stage-1 nail-down (post-steering-deferral)

After deciding to defer the tmux/home/steering question to Stage 2, closed the two
genuine Stage-1 acceptance gaps:
- **Live status banner in `quest open`** — `quest open` now renders a *view-time* copy of
  the quest HTML with a status strip injected after `<body>` (status, gate result glyphs,
  sessions on the quest, PR) built from head + runtime. The stored quest file is never
  mutated. This is the spec's "the plan always shows current progress without
  hand-maintenance."
- **Quest↔session link (observed state, no loop)** — `loadQuestRuntime` overlays the
  runtime record's `Sessions` live from the spine (manifests whose quest hat is this id,
  with agent/state), and reads a draft quest with an attached session as in_progress. The
  dashboard detail + the browser banner now show which agents are on a quest.
- PR/CI display stays wired to the runtime record (empty until Stage 2 writes it); the
  live GitHub query needs a worktree/branch, which arrives with the Stage 2 loop. Removed
  `quest new --plan` (quest-awareness is the system brief now).

## Stage-1 visual pass (dashboard quests + detail panes)

Confirmed the agents tracker is literally questmaster's (`quests agents` -> `tui.LaunchAgents`),
so no visual work needed there. Polished the quests + detail panes:
- App title bar (`✦ quests <n>`).
- Each quest row carries a live **status glyph** (◐ in_progress / ● done / ! blocked / ○ draft),
  compact **gate chips** (✓/✗/◐/☐/· per gate) and a **PR marker** (#num) — closes the
  "cockpit shows each quest's PR/CI" acceptance item.
- Refactored the dashboard data path to `QuestRow{Quest, Runtime}` (one batched
  DiscoverSessions + per-quest runtime), so list + detail share one live source.
- Cleaner detail pane: aligned label column, cyan section headers, session glyphs.
This is a starting point for visual nitpicks; colors/layout are all easily tuned.

## Stage-1 dashboard: single-pane accordion (right pane reserved for Stage 2 steer)

Per feedback (few simultaneous quests; the right pane should be the steering surface):
- Dropped the permanent detail pane. The dashboard is now a **single quests list**; the
  **selected** quest expands inline (accordion) to its full detail (status, tree, context,
  gates, next, sessions, PR). Collapsed quests are one-line summaries.
- The list **auto-scrolls** to keep the selected quest's block visible, so scrolling is
  driven by selection (no manual scroll mode).
- Chrome matches the tracker: borderless, dim ─ rule, background-fill selection on the
  selected summary line.
- The **right pane is reserved for Stage 2 steering** of headless sessions (its real
  purpose), rather than half-empty quest detail in Stage 1.

## Quests-owned tracker copy

Copied questmaster's `internal/tui` package verbatim to `internal/quests/tracker`
(package `tracker`) so the agents-tracker UI can be tweaked for Quests without touching
the frozen questmaster binary. `quests agents` now calls `tracker.LaunchAgents`; the
`LaunchAgents` helper that had been added to `internal/tui` was removed, restoring that
package to pristine (questmaster keeps using `tui.Launch`). Both packages share the same
spine (agent/state/tmux/session/message/palette); only the UI is duplicated, on purpose.

## T8 — free-session parity + planning authoring

- **`Mode`/`QuestID` on the model.** Added the skeleton-mandated two fields to
  `state.Manifest` (omitempty, with decode/marshal cases), so questmaster manifests
  are byte-for-byte unchanged. Rather than threading them through
  `session.Service.Start` (shared, frozen code), `quests session new` sets them with a
  post-spawn `Store.Update` only when a quest hat is attached — a free session is a
  *pure* questmaster `Start` with no extra writes, which is the parity guarantee.

- **Session sidebar runs `quests`, not `questmaster`.** `defaultSpawnSession` sets the
  Service's `CLIResolver` to resolve the `quests` binary (mirroring
  `config.ResolveQuestmasterCmd`), so the in-session compact cockpit is the Quests one.

- **State isolation for spawned sessions** rides the existing mechanism: `launch.go`
  propagates `QUESTMASTER_STATE_ROOT` (bootstrapped to the Quests state root) into the
  tmux session env, so the agent's global hooks write state under `~/.quests/state`.
  Stage 1 therefore needs no `quests hook` subcommand; it reuses questmaster's installed
  hook with the redirected root. (Flagged: live roster state requires questmaster's hook
  to be installed; documented for the gate.)

- **Planning flow.** `quest new <id> --plan` writes the validated scaffold via the Store
  (the authoring primitive) and then spawns an interactive master planning session seeded
  to elaborate the quest via `quests quest edit`. This is the concrete, testable
  realization of "a planning session authors a quest → a valid file under Home"; the
  agent's interactive elaboration is, by nature, not unit-tested.

## T2 — quest head parsing

- **In-string whitespace normalization.** The canonical `quest-template-example.html` wraps
  the `goal` value across two source lines for readability, so the `#quest-head` text content
  contains a literal newline + indentation *inside* a JSON string — which strict
  `encoding/json` (and browser `JSON.parse`) reject. `Parse` therefore normalizes runs of raw
  whitespace that occur inside string literals down to a single space before decoding. This is
  what makes the canonical template parse, as the handoff requires.
