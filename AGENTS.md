# AGENTS.md

Working guide for coding agents in this repo. It is orientation and guardrails,
not a straitjacket — when this file and the live code disagree, trust the code.
Keep this file accurate when you change something it describes.

## What this is

`questmaster` is a **tmux orchestration backend** (a Go CLI) for AI coding
agents: managed agent sessions are masters by default, they spawn workers, and
the CLI relays messages and exposes runtime state over a local socket. Plain
shell sessions remain shells.

`Questmaster.app` is the **native macOS human client** over that backend. It has
an AppKit shell with SwiftUI content surfaces, launches/connects to `qm serve`,
renders pushed runtime JSON, sends mutation requests over the same socket, and
embeds a libghostty terminal attached to the selected `qm-*` tmux session.

The CLI is **agent-first / automation-first**: most lifecycle, messaging, list,
and status success output is JSON; utility commands may emit text. Use `--text`
(e.g. `read --text`) only when you explicitly want terminal text. The CLI is not
a standalone human UI.

## Layout

```
main.go              # entry point → cmd.Execute()
cmd/                 # cobra command surface (one factory per *.go)
internal/            # all backend logic (see below)
app/                 # the macOS Swift package (Questmaster.app)
  Sources/Core/      # QuestmasterCore: pure logic (Foundation + Observation only)
  Sources/App/       # Questmaster: SwiftUI views, sockets, subprocesses
  Tests/             # QuestmasterLogicTests (Core-only, custom runner)
scripts/, app/Scripts/   # bench-hook.sh, build-app.sh
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

## Go backend architecture

- `main.go` → `cmd.Execute()`. Each `cmd/*.go` is a cobra command factory with
  its deps (state store, tmux client) injected so commands stay testable. A
  **hook fast-path** skips cobra parsing for valid `hook` event invocations,
  which fire often. Most backend workflow output is JSON; valid hook events log
  handler errors instead of propagating them, while usage/flag errors may still
  fail.
- Backend logic lives in `internal/`, one small package per concern — read the
  package doc comment to find the right one. The load-bearing boundaries are
  `session` (lifecycle), `state` (flock-guarded manifests + the hook-written
  session state/event log), `serve` (socket snapshots, mutations, and fsnotify
  watch backend), `tmux` (CLI wrapper behind a mockable `Runner`), and `agent`/`hooks`
  (per-CLI integration).

Invariants that aren't obvious from the code:

- The Go↔Swift wire contract is `internal/serve/testdata/*.json` (see next section),
  not any single Go type — version it deliberately.
- **No model or reasoning-effort list is hardcoded.** Each harness declares its
  catalog sources and effort source once in `agent.Spec`; `modelsuggest`
  resolves model choices at runtime and reads effort support from the harness.
  Model ids are never validated — `--model` is passed through verbatim. Effort
  validation rejects a value only when the harness reports levels for that
  model. When adding a harness, declare its sources; never add model or effort
  values to a list. Tests must disable the models.dev catalog (or inject a
  fetcher) and inject effort-source fixtures so they never access the network,
  real harnesses, or the real Codex cache.

## The Go↔Swift contract

`internal/serve/testdata/*.json` are the single source of truth for the serve wire
shapes (tracker, dir_suggest and models payloads + response/event envelopes). Both the
Go serve golden test and the Swift app's contract-fixture test decode the same
files. If you change a serve payload shape, **regenerate the goldens and update
both sides in the same change**:

```sh
go test -buildvcs=false ./internal/serve -update
```

## Swift app architecture

**Keep app logic in Core and UI decisions close to the existing shell.** The app
targets macOS 14, so `@Observable` and `.onKeyPress` are available for SwiftUI
surfaces. The current App target also owns AppKit window/split-view, key routing,
menus, terminal, and platform boundary code.

**`QuestmasterCore` is pure.** It imports only `Foundation` and `Observation` —
no AppKit, SwiftUI, or WebKit. All decisions, parsing, state machines, mutation
builders, and the `@Observable` stores live there, each with a matching
`XxxTests`. The `Questmaster` (App) target holds the I/O and platform boundary —
sockets, file watchers, subprocesses, AppKit shell, and SwiftUI views. A view
renders shared state and dispatches commands; **a domain decision belongs in
Core, not in a view callback.** Keep views small.

- **Inbound:** `qm serve` pushes runtime JSON over the Unix socket; the app
  decodes each line and applies it to the `@Observable` `RuntimeStore`. Views
  read the stores directly and mutate state only through store methods.
- **Outbound:** mutation builders in `Core/Mutations` build request objects;
  `App/Runtime/ServeMutationClient.swift` sends newline-delimited serve
  request/response JSON over the same Unix socket (not CLI invocation).
- **Terminal:** a libghostty terminal attaches to a `qm-*` tmux session via a
  generated startup script. Its child-process env is sanitized — it **strips
  `TMUX`/`TMUX_PANE`/`TMUX_TMPDIR`** so the terminal never connects to a stray
  tmux socket.
- **Styling:** style every view from the shared token layer (`Token`,
  `AppPalette`, `AppFonts`) — no raw hex or magic-number radii/spacing.

**Use AppKit where the current shell or platform boundary requires it:** the
window, custom `MainSplitView`, first-responder/key mechanics, menus, global key
monitors, web/artifact bridges, and GhosttyKit terminal boundary are AppKit or
AppKit-adjacent. Prefer SwiftUI for content surfaces and keep domain logic in
Core.

## Interaction states

One set of state rules covers the whole app. A view asks for a state's look
(`RowLook`, `OutlineLook`, `ToggleLook`, `PlateBand` in
`Core/Rendering/InteractionLook.swift`) and draws it; it never picks a palette
colour by state itself. The colours are `StateColor` cases, which `AppPalette`
builds its matching entries from (`SharedUI/Theme.swift`).

The mouse highlights, the keys move the cursor, and a click acts. The pointer
shows the hover look (`RowLook.hovered`: a 1pt `line` outline, no fill, text
and icon unchanged; every cursor and selection look is filled, so the two never
read alike) on the row under it, via `stateRow`, and moves no list's cursor or
selection. Return, Tab and Save
commit the keyboard cursor; a row the pointer only crossed needs a click. The
one exception is the tracker while it has the keys: hover moves its cursor
(`highlightOnHover`, real pointer motion only), and its list doesn't scroll to
a cursor the pointer moved, and drops a key scroll still queued
(`PointerCursor`). A pill tab is already `item`
filled, so tabs have no hover look.

A region has the keys while it's focused and no modal is drawn
(`NavigationStore.hasKeys`); its focus looks follow that. When the user leaves
a region, a selection that lasts (a tab row's) and a cursor whose design draws
an unfocused state (the artifact list's) stay one step dimmer; a pure cursor
with no lasting selection and no designed unfocused state (the tracker's)
hides.

| Element | State | Look |
|---|---|---|
| Pick-to-open row (artifacts, dropdowns, filter suggestions) | rest | no fill, `textBody` #D8DEE9, icon tile border `line`, icon and meta `textMeta` #9DA7B1 |
| | highlighted, area focused (`RowLook.highlighted`) | `item` fill, `textSelected` #E6EDF3, icon tile border `controlBorder`, icon `textSelected`, meta `textMetaHighlighted` #ADBAC7 |
| | highlighted, area unfocused (`RowLook.highlightedUnfocused`) | `item` fill, `textBody` text and icon, icon tile border `controlBorder`, meta `textMeta` #9DA7B1 |
| | missing file (`RowLook.missingFile`) | the row's look with a `warn` icon |
| | marked for deletion (`MarkLook`) | `accent` diamond in the row's left gutter |
| Any row | under the pointer (`RowLook.hovered`) | 1pt `line` outline, no fill; text, icon and meta as at rest |
| Lasting-selection row (the Quest Log) | selected (`RowLook.selected`) | `item` fill, **bold** `textSelected` |
| Tab (agent tabs, Session/All, Settings sidebar) | rest (`OutlineLook.tabRest`) | `line` outline, `textBody` |
| | selected (`.tabSelected`) | `controlBorder` outline, `textSelected` |
| | selected, area unfocused (`.tabSelectedUnfocused`) | `controlBorder` outline, `textBody` |
| Field | rest / focused (`.fieldRest` / `.fieldFocused`) | `line` / `controlBorder` border (`fieldChrome`) |
| Dock frame | rest / focused (`.frameRest` / `.frameFocused`) | 2pt `lineSoftSubtle` / `controlBorder` |
| Icon button (top bar, action bar) | rest / under the pointer | `RowLook` icon: `textMeta` / `textSelected` |
| Toggle (action bar) | on (`ToggleLook.on`) | `brassActive` border and inner glow |
| Tracker plate | cursor, while the tracker has the keys (`PlateBand.showsCursor`) / under the pointer / recolouring | `textSelected` / `controlBorder` / `accent` band; no band otherwise |

- Bold means selected and appears only in a lasting-selection list. Artifacts
  have no selected state: picking one opens it.
- Dividers inside rows are `line` in every state.
- Brass and glow mean "on", for toggles only. One gold, `accent` #D7B13D, for
  titles, project headers and marks; never for selection or focus.
- No shadows on dropdowns or panels. Panel, dock and toast borders are 2pt
  `lineSoftSubtle` (`ScoopedRectangle.borderWidth`). The dock's frame lifts to
  `controlBorder` while the dock has keyboard focus and no modal is drawn
  (`OutlineLook.frame`, `ShellFocusCoordinator.updateRegionKeys`). Pressed is
  0.8 opacity; disabled is window fill with `item` border and label (the shared
  button styles).
- Use the shared components: `stateRow` for rows (`ListRow` for the tracker's
  plates), `PillTab`/`PillTabRow` for tabs (no icon: no disc),
  `fieldChrome`/`FormTextField` for fields, `FilterBar` for filter fields,
  `SuggestionDropdown` for every dropdown and suggestion list, `FilterChip` for
  filter chips, the `AngledButton` styles for buttons.
- Dock titles (Artifacts, Worker Chat, an open artifact) are title case in
  `accent`, 14pt bold, on the top bar's baseline 35 down.

`StateRulesScanTests` (in the logic-test runner) scans `app/Sources/App` and
fails on a raw colour outside `Theme.swift`, a `StateColor`/`textSelected`
outside the token layer, `brassActive` or `ToggleLook` outside the action bar, a
view picking a colour by a state flag, and a hand-rolled dropdown or field. It
must find no breaks.

## Spacing

Everything is on 5s. Every gap, margin, padding, inset, pitch and control size
is a multiple of 5, and spacing takes one of four steps (`Space` in
`SharedUI/DesignTokens.swift`), or a sum of them:

| Step | Value | Role |
|---|---|---|
| `Space.row` | 5 | rows of one list control; a field and its dropdown; collapsed circles; the cast row under its disc |
| `Space.item` | 10 | sibling items (plates, tabs, buttons, chat entries, bar icons); icon → text; text inset inside a control; header band → content |
| `Space.section` | 20 | the shell gap (`ShellMetrics.gap`); every panel's edge margin; blocks inside a panel |
| `Space.group` | 40 | between groups of blocks: the selected-session panel → the list |

Control heights are one family (`ControlHeight`): `chip` 15, `compact` 25
(pill tabs, Quest Log rows), `control` 30 (buttons, dropdown rows), `field` 35
(fields, filters, the Settings picker), `bar` 40 (the dock top bar, artifact
rows), `row` 50. A shape drawn from a design at another height keeps its path's
own height as a `design…` constant and scales to the control's.

Not spacing, so free of the rule: text baselines and line heights, optical
nudges that centre text or a glyph inside a control, path data and art
canvases, glyph and logo sizes, radii and stroke widths, and 0/1 spacers. A
design value that isn't on 5s is snapped to the nearest 5, never kept with a
marker.

`SpacingRulesScanTests` (in the logic-test runner) enforces it and must find no
breaks:

- **raw-spacing**: no layout number in a view (`.padding`, stack `spacing`,
  `.frame` sizes, `EdgeInsets`, constraint constants, `.offset`), except 0 and 1
  and lines inside an `enum` named `*Metrics`, `*Layout` or `*Design`.
- **scale-restated**: a gap/inset/spacing/margin/padding/gutter constant of 5,
  10, 20 or 40 names its `Space` step.
- **off-rhythm**: a CGFloat constant or default named as a length (gap,
  spacing, margin, padding, gutter, pitch, indent, inset, clearance, offset,
  height, width, side, size) is a multiple of 5. Only names that say they aren't
  spacing are exempt (`baseline`, `lineHeight`, `radius`, `stroke`, `border`,
  `ring`, `glow`, `pointSize`, `font`, and `art`/`design`/`glyph`/`icon`/`logo`/
  `mark`/`symbol`/`ink` geometry).

The scan reads lines, so `testRenderedSpacingStaysOnTheScale` (a
`--run-logic-tests` self-test) measures rendered pixels for what it can't see:
the artifact rows' 45pt pitch and a form's fields 10 under the header band and
20 apart.

## Testing conventions

- **Go:** stdlib `testing` only (no testify), table-driven, `t.Parallel()`,
  `t.Helper()` on helpers. State uses a `t.TempDir()` store; tmux is mocked via a
  `Runner` func. Goldens live in `testdata/` dirs.
- **Swift:** Core-only, via a custom runner in
  `app/Tests/QuestmasterLogicTests/main.swift` (no XCTest). Add a pure-Core suite
  by appending `XxxTests.run()` there. The runner also spawns
  `Questmaster --run-logic-tests` and asserts a non-zero
  `Questmaster self-tests: ... passed` line. **UI is not unit-tested**; verify it
  by building and by manual/bench checks.

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
