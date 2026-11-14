# AGENTS.md

Working guide for coding agents in this repo: orientation and guardrails, not a
straitjacket. When this file and the live code disagree, trust the code. Keep this
file, and the skill reference that describes a thing, accurate when you change it.
Detail lives in project skills: read the file the "Skills index" row names first.

## Workflow

- Keep `internal/agent/prompts/` to Questmaster role identity, session mechanics,
  and CLI behavior. Delegation thresholds, reviewer cadence, model preferences,
  and general writing or repository practices belong to the user or applicable
  project instructions, not the injected session prompt.
- Master launches include the class voice from `internal/agent/prompts/class_voice.md`
  and the matching `class_voice/<class>.md`; workers do not receive it. Claude
  and Pi use their appended system prompt, Codex uses `developer_instructions`,
  and OpenCode selects a managed per-class master agent file. The voice is fixed
  at launch; reclassing takes effect on the next launch, including continuing a
  stopped session or restarting it.
- Branch from a freshly fetched `origin/main` (`git fetch origin`, then
  `git worktree add <path> -b <branch> origin/main`), never from a local `main`:
  it can be stale or still on a history `main` has since rewritten, and a PR
  cut from it drags that old history along. Before opening a PR, check that
  `git log origin/main..HEAD` lists only its own commits. App work and backend
  work both ship as PRs **direct to `main`** (there is no long-lived integration
  branch). Open **draft** PRs by default. Prefer separate PRs for backend vs app
  when the change is separable.
- Do file edits inside a **dedicated git worktree** so concurrent sessions don't
  trample each other.
- **Do not drive the GUI via AppleScript/`osascript`/synthetic keystrokes** — it
  trips endpoint security here. Verify app changes via `swift build` + the logic
  tests; leave interactive GUI verification to the human.

## Hard rules

- **Always pass `-buildvcs=false` to `go build`.** A bare `go build` exits 128 here
  (a broken `~/.git`), in CI and locally.
- **Agents never run `build-app.sh` or `install-app.sh` against the real install.** A
  test run uses a temporary `--install-path`, `HOME` and `QUESTMASTER_STATE_ROOT` with
  `--isolated` (the installer refuses a mix). Merging backend changes to `main` does
  not make them live in the app until the bundle is rebuilt: the app ships its own `qm`.
- **Commands run for or by a dev session use `$QUESTMASTER_BIN`** (or the dev shim
  directory first on `PATH`), never the installed `questmaster`/`qm`. A shell that
  carries the real install's `QUESTMASTER_BIN` passes it to the panes it creates:
  unset it before running a dev `qm` by hand.
- **Every tmux call names its server and its session exactly.** New sessions use
  `tmux.DefaultServer()` (`-L questmaster`, or the validated development label);
  existing sessions use the `tmux_server` in their manifest through `tmuxroute.Router`.
  Session targets are `tmux.SessionTarget` (`=name:`), never a bare name, which tmux
  matches by prefix. A pane is targeted by the ID `NewSession` reports, never by index.
  Commands run without TMUX, TMUX_PANE and TMUX_TMPDIR, which describe the caller's
  own server. The user's default server has no operational route.

## What this is

`questmaster` is a **tmux orchestration backend** (a Go CLI) for AI coding
agents: managed sessions are masters by default, they spawn workers, and the CLI
relays messages and exposes runtime state over a local socket. Plain shell
sessions remain shells. `Questmaster.app` is the **native macOS client** over it
(AppKit shell, SwiftUI surfaces, an embedded libghostty terminal attached to the
selected `qm-*` session); it connects to `qm daemon` and sends mutations over the
same socket. The CLI is **agent-first**: most success output is JSON; use `--text`
(e.g. `read --text`) only when you want terminal text.

## Layout

```
main.go              # entry point → cmd.Execute()
cmd/                 # cobra command surface (one factory per *.go)
internal/            # all backend logic (see below)
app/                 # the macOS Swift package (Questmaster.app)
  Sources/Core/      # QuestmasterCore: pure logic (Foundation + Observation only)
  Sources/App/       # Questmaster: SwiftUI views, sockets, subprocesses
  Tests/             # QuestmasterLogicTests (Core-only, custom runner)
scripts/, app/Scripts/   # bench-hook.sh, build-app.sh, install-app.sh (+ test-install.sh)
.agents/skills/      # project skills (real files); .claude/skills/ symlinks to them
```

## Build, test, run

**Go backend** (matches CI in `.github/workflows/ci.yml`):

```sh
go mod tidy          # CI then verifies: git diff --exit-code -- go.mod go.sum
go build -buildvcs=false ./...
go vet ./...
go test ./...
```

**macOS app** (macOS only; needs AppKit and a fetched GhosttyKit `xcframework`):

```sh
swift build --package-path app                          # compile
swift run --package-path app QuestmasterLogicTests      # Core + app self-tests
```

State lives at `~/.questmaster-state` (override with `QUESTMASTER_STATE_ROOT`).
Building, installing and branch-running the app bundle: `app-bundle` skill.

## Go backend

- Each `cmd/*.go` is a cobra command factory with its deps (state store, tmux
  client) injected. A **hook fast-path** skips cobra parsing for valid `hook` events,
  which fire often; their handler errors are logged, not propagated.
- Logic lives in `internal/`, one small package per concern: read the package doc
  comment. Load-bearing boundaries: `session` (lifecycle), `state` (flock-guarded
  manifests, hook-written session state), `serve` (socket snapshots, mutations),
  `tmux` (CLI wrapper behind a mockable `Runner`), `tmuxroute`, `daemon`, `agent`/`hooks`.
  Lifecycle and inventory detail: `tmux-lifecycle`. Closing is not deleting.
- A session cwd, artifact, quest or color seed takes its project ID from
  `state.ProjectResolver` (`state.ProjectIDAt` for one-shot callers), never from a raw `repo.Resolve`.
- **The Go↔Swift wire contract** is `internal/serve/testdata/*.json`, decoded by both
  the Go golden test and the Swift contract-fixture test. Bump `ServeProtocolVersion`
  for any payload change an old decoder cannot read; regenerate the goldens and update
  both sides in the same change:

  ```sh
  go test -buildvcs=false ./internal/serve -update
  ```

  The tracker session row carries an optional `last_exchange` object, `{"kind": "instructions" | "report", "at": RFC3339}`.
  It is set only when a master messages a worker or a worker reports to its master, and spawn prompts leave it empty. The
  class avatar diffs it between payloads to play its message and report cues (`TrackerAvatarEventDetector`), so status and
  action chat entries don't change it. Old decoders ignore the key, so it needed no `ServeProtocolVersion` bump.

  The row also carries `active_subagents`, the count of sub-agents the session has running. Only Claude reports them: the
  hooks add an id on `SubagentStart` and remove it on `SubagentStop` (a stop with no matching start is ignored, and so is a
  start with no agent type or an `internal` one), and both `starting` and `stopped` clear the set. A finished turn keeps its
  sub-agents until they stop. The key is omitted at zero, and it needed no `ServeProtocolVersion` bump either.
- **No model or reasoning-effort list is hardcoded.** Each harness declares its
  catalog sources and effort source once in `agent.Spec`; model ids are passed
  through verbatim. When adding a harness, declare its sources; never add values to a list.
- **Delivery labels are what happened:** `accepted` (a native socket took the frame),
  `submitted` (tmux `send-keys` typed it), or empty (alert held). Never label a tmux
  send as received.

## Swift app

- **`QuestmasterCore` is pure:** it imports only `Foundation` and `Observation`. All
  decisions, parsing, state machines, mutation builders and `@Observable` stores live
  there, each with a matching `XxxTests`. The App target holds I/O, the AppKit shell
  and SwiftUI views. A view renders shared state and dispatches commands; **a domain
  decision belongs in Core, not in a view callback.** The app targets macOS 14.
- Views mutate state only through store methods; mutations go over the daemon's Unix
  socket (`App/Runtime/ServeMutationClient.swift`), not by CLI invocation.
- The terminal's child env **strips `TMUX`/`TMUX_PANE`/`TMUX_TMPDIR`**.
- **Style every view from the shared token layer** (`Token`, `AppPalette`, `AppFonts`,
  `Space`, `ControlHeight`, `MotionStep`): no raw hex, radii, spacing or durations.

### UI scan tests

`swift run --package-path app QuestmasterLogicTests` runs three source scans of
`app/Sources/App`, and a break fails it:

- `StateRulesScanTests`: a raw colour or hand-picked state colour outside `Theme.swift`, a hand-rolled dropdown or field.
- `SpacingRulesScanTests`: a raw layout number or non-multiple-of-5 length outside `*Metrics`/`*Layout`/`*Design`.
- `MotionRulesScanTests`: a literal animation duration or curve outside the token layer.

Not scanned: hover moves no cursor and a click acts; rows, tabs, fields, dropdowns and
buttons are the shared components; an empty list is one icon; every modal follows one key rule.
**Before editing a view under `app/Sources/App`, read `.agents/skills/app-ui/SKILL.md`.**

## Testing conventions

- **Go:** stdlib `testing` only (no testify), table-driven, `t.Parallel()`,
  `t.Helper()` on helpers. State uses a `t.TempDir()` store; tmux is mocked via a
  `Runner` func. Goldens live in `testdata/` dirs. Tests that resolve the state root
  set `QUESTMASTER_STATE_ROOT` to a temporary directory (the resolver rejects the
  live root). Tests that need real tmux use `internal/tmux/tmuxtest` (a private `-S`
  socket, TMUX vars stripped), are named `TestIntegration…` and call
  `tmuxtest.RequireIntegration` (they run only with `QUESTMASTER_TMUX_INTEGRATION=1`,
  as in the `tmux-integration` CI job); production code must not import `tmuxtest`.
  `tmux.Server` rejects named `-L` selections in test binaries. Tests never reach the
  network, real harnesses or the real Codex cache: disable the models.dev catalog (or
  inject a fetcher) and inject effort-source fixtures.
- **Swift:** Core-only, via a custom runner in
  `app/Tests/QuestmasterLogicTests/main.swift` (no XCTest). Add a pure-Core suite
  by appending `XxxTests.run()` there. The runner also spawns
  `Questmaster --run-logic-tests` and asserts a non-zero
  `Questmaster self-tests: ... passed` line. **UI is not unit-tested**; verify it
  by building and by manual/bench checks.
- `internal/agentdocs` keeps this file under its size cap and checks that every
  skill, symlink and pointer below resolves. Keep the root short; put detail in a skill.

## Skills index

Skills are real files in `.agents/skills/<name>/` (Codex, Pi and OpenCode read that path;
`.claude/skills/<name>` symlinks to it for Claude Code). Skill triggering is by
description and not guaranteed, so **read the file named here with your ordinary file
tool whenever its row applies**.

| When you are… | Read |
|---|---|
| Editing any SwiftUI/AppKit view, token, colour, spacing, animation, key handling, empty or loading state, or modal | `.agents/skills/app-ui/SKILL.md` (then the reference it names) |
| Editing the tracker, Worker Log, Watcher, dock column, action bar header or Quest Log | `.agents/skills/app-surfaces/SKILL.md` |
| Changing tmux routing, server inventory, manifests, runtime dirs, or close/delete/prune/audit | `.agents/skills/tmux-lifecycle/SKILL.md` |
| Building, installing, rolling back or running `Questmaster.app`, or touching `app/Scripts/` | `.agents/skills/app-bundle/SKILL.md` |
| Changing the class avatar, its sprites, `animation.json`, its cues or the session banner | `.agents/skills/class-avatar/SKILL.md` |
