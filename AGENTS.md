# AGENTS.md

Working guide for coding agents in this repo. It is orientation and guardrails,
not a straitjacket — when this file and the live code disagree, trust the code.
Keep this file accurate when you change something it describes.

## What this is

`questmaster` is a **tmux orchestration backend** (a Go CLI) for AI coding
agents: it starts sessions, promotes one to a master, spawns workers, relays
messages, runs quests, and exposes runtime state over a local socket.

`Questmaster.app` is the **native SwiftUI human client** over that backend. It
launches/connects to `qm serve`, renders pushed runtime JSON, and embeds a
libghostty terminal attached to the selected `qm-*` tmux session.

The CLI is **agent-first / automation-first**: non-interactive success output is
JSON by default. Use `--text` (e.g. `quest view --text`, `read --text`) only
when you explicitly want terminal text. The CLI is not a standalone human UI.

## Layout

```
main.go              # entry point → cmd.Execute()
cmd/                 # cobra command surface (one factory per *.go)
internal/            # all backend logic (see below)
contract/testdata/   # golden JSON — the Go↔Swift wire contract
app/                 # the macOS Swift package (Questmaster.app)
  Sources/Core/      # QuestmasterCore: pure logic (Foundation + Observation only)
  Sources/App/       # Questmaster: SwiftUI views, sockets, subprocesses
  Tests/             # QuestmasterLogicTests (Core-only, custom runner)
scripts/, app/Scripts/   # bench-hook.sh, build-app.sh
spikes/              # dev-only validators (e.g. opencode-harness)
```

## Build, test, run

**Go backend** (matches CI in `.github/workflows/ci.yml`):

```sh
go mod tidy          # CI then verifies: git diff --exit-code -- go.mod go.sum
go build -buildvcs=false ./...
go vet ./...
go test ./...
```

`-buildvcs=false` is required here — both in CI and locally (a bare `go build`
exits 128 in this environment because of a broken `~/.git`). Always pass it.

**macOS app** (macOS only — depends on AppKit and a fetched GhosttyKit
`xcframework`; it does **not** build on Linux):

```sh
swift build --package-path app                          # compile
swift run --package-path app QuestmasterLogicTests      # Core + app self-tests
./app/Scripts/build-app.sh                              # full bundle → /Applications
```

`build-app.sh` builds the Swift executable, fetches/embeds GhosttyKit, **builds
the Go `qm` binary into the bundle**, ad-hoc codesigns, and installs. Because the
app ships its own `qm`, **merging backend changes to `main` does not make them
live in the app until the bundle is rebuilt.**

State lives at `~/.questmaster-state` (override with `QUESTMASTER_STATE_ROOT`).
Quests live under `~/.questmaster/quests`, authored only via `qm quest *` — never
written into the repo.

## Go backend architecture

- `main.go` → `cmd.Execute()`. Each `cmd/*.go` is a cobra command factory with
  its deps (state store, tmux client) injected so commands stay testable. A
  **hook fast-path** skips cobra parsing for the `hook` command, which fires
  often. Non-interactive output is JSON; the `hook` command always exits 0 (it
  logs, never propagates errors).
- Backend logic lives in `internal/`, one small package per concern — read the
  package doc comment to find the right one. The load-bearing boundaries are
  `session` (lifecycle), `state` (flock-guarded manifests + the hook-written
  session state/event log), `serve` (the socket snapshot + fsnotify watch
  backend), `quests` (model, gates, lifecycle, merge-back), `tmux` (CLI wrapper
  behind a mockable `Runner`), and `agent`/`hooks` (per-CLI integration).

Invariants that aren't obvious from the code:

- **Quest status is human-owned** — agents toggle gates; only the Questmaster
  sets `wip→active→done`.
- **Merge-back is best-effort** — a failed worker→master merge never blocks a
  quest's status transition.
- The Go↔Swift wire contract is `contract/testdata/*.json` (see next section),
  not any single Go type — version it deliberately.

## The Go↔Swift contract

`contract/testdata/*.json` are the single source of truth for the serve wire
shapes (board/tracker/quest payloads + response/event envelopes). Both the Go
serve golden test and the Swift app's contract-fixture test decode the same
files. If you change a serve payload shape, **regenerate the goldens and update
both sides in the same change**:

```sh
go test -buildvcs=false ./internal/serve -update
```

## Swift app architecture

**Build the UI in SwiftUI.** The app targets macOS 14, so `@Observable` and
`.onKeyPress` are available — use them. Reach for AppKit only where SwiftUI
genuinely can't (see exceptions below).

**`QuestmasterCore` is pure.** It imports only `Foundation` and `Observation` —
no AppKit, SwiftUI, or WebKit. All decisions, parsing, state machines, mutation
builders, and the `@Observable` stores live there, each with a matching
`XxxTests`. The `Questmaster` (App) target holds the I/O boundary — sockets,
file watchers, subprocesses — and the SwiftUI views. A view renders shared state
and dispatches commands; **a domain decision belongs in Core, not in a view
callback.** Keep views small.

- **Inbound:** `qm serve` pushes runtime JSON over the Unix socket; the app
  decodes each line and applies it to the `@Observable` `RuntimeStore`. Views
  read the stores directly and mutate state only through store methods.
- **Outbound:** mutation builders in `Core/Mutations` send **JSON-RPC over the
  same Unix socket** (not CLI invocation).
- **Terminal:** a libghostty terminal attaches to a `qm-*` tmux session via a
  generated startup script. Its child-process env is sanitized — it **strips
  `TMUX`/`TMUX_PANE`/`TMUX_TMPDIR`** so the terminal never connects to a stray
  tmux socket.
- **Styling:** style every view from the shared token layer (`Token`,
  `AppPalette`, `AppFonts`) — no raw hex or magic-number radii/spacing.

**AppKit only where SwiftUI can't reach:** the GhosttyKit terminal and the
rich-text quest viewer (interactive `NSTextView`) live behind
`NSViewRepresentable`, plus low-level window / first-responder mechanics, menus,
and global key monitors. Everything else is SwiftUI.

## Testing conventions

- **Go:** stdlib `testing` only (no testify), table-driven, `t.Parallel()`,
  `t.Helper()` on helpers. State uses a `t.TempDir()` store; tmux is mocked via a
  `Runner` func. Goldens live in `testdata/` dirs.
- **Swift:** Core-only, via a custom runner in
  `app/Tests/QuestmasterLogicTests/main.swift` (no XCTest). Add a pure-Core suite
  by appending `XxxTests.run()` there. The runner also spawns
  `Questmaster --run-logic-tests` and asserts `Questmaster self-tests: N passed` —
  if you add app-side self-tests, bump `N` in `main.swift`. **UI is not
  unit-tested**; verify it by building and by manual/bench checks.

## Workflow

- Branch from `main`. App work and backend work both ship as PRs **direct to
  `main`** (there is no long-lived integration branch). Open **draft** PRs by
  default. Prefer separate PRs for backend vs app when the change is separable.
- Do file edits inside a **dedicated git worktree** so concurrent sessions don't
  trample each other.
- **Do not drive the GUI via AppleScript/`osascript`/synthetic keystrokes** — it
  trips endpoint security here. Verify app changes via `swift build` + the logic
  tests; leave interactive GUI verification to the human.

## Where to look

- `README.md` — install, backend quick start, native-app overview, env vars.
