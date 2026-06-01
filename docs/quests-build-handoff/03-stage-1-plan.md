# Stage 1 — The Plan Layer (task plan)

**Goal:** the quest file + cockpit, on the existing questmaster spine, running alongside questmaster with isolated state. No gates execution, no loop, no headless, no agent-initiated quests — those are Stage 2/3.

Tasks are ordered; each is a vertical slice that ends with `go build ./...`, `go test ./...`, `go vet ./...` green. Acceptance items marked **[auto]** are machine-checkable (the agent self-verifies); **[human]** are your check-in gates.

---

## T0 — Spine parameterization (refactor, in questmaster)

**Scope.** Thread a namespace value (state root, tmux prefix, branch prefix) through `internal/state`, `internal/tmux`, and session/branch naming, replacing questmaster's hardcoded defaults with an injected value. Add the `cmd/quests` binary skeleton (cobra root + version; bare command prints a "cockpit TODO" placeholder) so the module builds two binaries.

**Depends on:** nothing. **This is the first slice.**

**Acceptance.**
- [auto] Both binaries build (`go build ./...`); `go test ./...`, `go vet ./...` green.
- [auto] `cmd/questmaster`'s existing tests pass **unchanged** — behavior is preserved.
- [auto] A test asserts `quests`-resolved paths are rooted under `~/.quests` (or `QUESTS_HOME`), distinct from questmaster's `~/.questmaster-state`.

**Non-goals:** any quest logic; any TUI.

---

## T1 — `internal/quests/paths`

**Scope.** `Paths` + `Resolve()` with precedence defaults ← env (`QUESTS_HOME`) ← flags. Helpers for the quest-store dir (`<Home>/quests`), runtime dir, socket/fifo dir, and branch name from a quest id.

**Depends on:** T0.

**Acceptance.**
- [auto] Unit tests for precedence (default vs env vs flag) and for each path helper; `QUESTS_HOME` override respected.

**Non-goals:** writing files.

---

## T2 — `internal/quests/quest` — types, parse, validate

**Scope.** `Quest`, `Gate`, `GateType`, `Document` types (per skeleton §3). `Parse([]byte)` extracts the `id="quest-head"` JSON head and the HTML body. `Validate(Quest)` enforces the schema: `auto` requires `check`; `toggle` forbids `check`; `before ∈ {"", "pr"}`; required fields present.

**Depends on:** T1.

**Acceptance.**
- [auto] Golden test: parsing `quest-template-example.html` yields the expected head and body.
- [auto] A table of malformed heads is each rejected with a clear, specific error.
- [auto] A valid quest passes.

**Non-goals:** storage, rendering, any gate execution.

---

## T3 — Quest store (dotfile location)

**Scope.** `Store` (`Load`/`Save`/`List`/`Path`) rooted at `<Home>/quests/<id>.html`. `Save` re-validates the head and **refuses** a malformed one, returning the error to feed back. The store must never write into a repo.

**Depends on:** T1, T2.

**Acceptance.**
- [auto] Round-trip: `Save` → `Load` preserves head + body.
- [auto] `Save` of a malformed head is refused with the validation error.
- [auto] `List` returns heads; `Path(id)` is under `Home` — a test asserts it is **not** under any repo/worktree path.

**Non-goals:** runtime record, TUI.

---

## T4 — `internal/quests/runtime` — runtime record

**Scope.** `RuntimeRecord` type (skeleton §3); read/write beside the quest under `Home`. Stage 1 populates `Status`, `Sessions`, `PR`; `GateResults`/`Attempts` exist but stay empty.

**Depends on:** T1.

**Acceptance.**
- [auto] Round-trip read/write; record lives under `Home`, not a repo.

**Non-goals:** populating gate results / attempts.

---

## T5 — `internal/quests/adapter` — read-only status + context

**Scope.** `StatusSource.PR(repo, branch)` returning `PRStatus` (CI + review state), built on projdash's existing GraphQL/`gh` read path (reuse/port — read-only). `ContextSource.Resolve(ref)` reading Linear/Notion/Slack via the existing MCP connectors (thin pass-through is fine).

**Depends on:** T1.

**Acceptance.**
- [auto] Against a recorded/mock GitHub response, `PR()` returns the correct CI/review state. No network in unit tests.
- [auto] `ContextSource.Resolve` returns text for a mock ref.

**Non-goals:** status write-back to `primary_ref` (Stage 2).

---

## T6 — `cmd/quests` CLI surface

**Scope.** Cobra subcommands: `quest new|edit|view|open|ls|diff`, wired to Store / runtime / adapter. `quest open` → browser. `quest edit` → `$EDITOR`, re-validate on save. `quest diff <id>` → `review.DiffViewer.Open(worktree, base)` — default scry, swappable via `--viewer`/env (include the small `review` package here). `quest view` prints the head + runtime summary.

**Depends on:** T2, T3, T4, T5.

**Acceptance.**
- [auto] `quest new` writes a valid file under `Home`; `quest ls` lists it.
- [auto] `quest edit` round-trips and **rejects** a corrupted save.
- [auto] `quest diff` invokes the configured viewer — assert the built command via a fake viewer; default is scry, override honored.

**Non-goals:** the cockpit TUI; `dispatch`; `done`.

---

## T7 — `internal/quests/cockpit` — the TUI

**Scope.** Bubble Tea three-pane: **roster** (sessions across repos, from the reused state store) | **quests** (from `Store`) | **detail** (quest head + runtime overlay + PR/CI from the adapter + open-in-browser + a key that triggers `quest diff`). Reuse questmaster's tui patterns/palette. Bare `quests` launches this.

**Depends on:** T3, T4, T5, T6.

**Acceptance.**
- [auto] Model unit tests: list population, pane focus, key handling, ANSI-stripped render assertions (mirror how questmaster/projdash test TUIs).
- [human] **The cockpit actually reads as a usable replacement for your manual HTML-plan + index habit.** Surface for review.

**Non-goals:** steer-into-headless (no headless this stage); live gate glyphs (results empty in Stage 1).

---

## T8 — Free-session parity + planning-session authoring

**Scope.** `quests session new` spawns an **interactive** tmux session via the reused `session.Service` under the quests namespace — a free session (no quest) behaves exactly as questmaster today. A **planning** session authors a quest: the planner writes a `Document` through `Store` (validated on save).

**Depends on:** T0 (namespace), T3 (store), T7 (cockpit).

**Acceptance.**
- [auto] A free session spawns detached and appears in the roster; a planning flow produces a valid quest file under `Home`.
- [human] **Free-session spawn/drive feels as fast and fluid as `prefix+p` in questmaster today** — the parity gate.
- [human] **The cockpit + quest authoring genuinely replaces the manual index workflow.**

**Non-goals:** gates, the loop, `dispatch`-on-quest, headless execution.

---

## Stage 1 done

All `[auto]` acceptance green across T0–T8; the `[human]` gates (T7 usability, T8 parity) reviewed and accepted by you; `quests` runs alongside `questmaster` with zero shared state. That is the milestone where you step in to actually use it — and the entry point to Stage 2 (gates + the loop).
