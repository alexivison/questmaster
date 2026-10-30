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
an AppKit shell with SwiftUI content surfaces, starts/connects to `qm daemon`,
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
- `daemon` owns the lock, ready handshake, idle lifetime, re-exec upgrade,
  clean child environment and identity shims. It uses `serve.Server` as its
  request layer for runtime snapshots, mutations and subscriptions.
- `prstatus` polls watched PR status and new comments, reviews, CI results and
  state changes. `pull_requests.json` stores watches, event history and each
  watcher's read/alert cursors under one lock. `message.Service.Notify` gates
  background alerts on live, idle or done sessions and recent tmux input.
  The status query also reads the authenticated viewer login; this one-way
  personal setup ignores that author's discussion before recording events.

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

`internal/serve/testdata/*.json` are the single source of truth for the runtime wire
shapes (tracker, pull_requests, dir_suggest and models payloads + response/event envelopes). Both the
Go runtime golden test and the Swift app's contract-fixture test decode the same
files. Bump `ServeProtocolVersion` for any payload change an old decoder cannot read.
If you change a serve payload shape, **regenerate the goldens and update
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

- **Inbound:** `qm daemon` pushes runtime JSON over the Unix socket after a
  verified ready handshake; the app
  decodes each line and applies it to the `@Observable` `RuntimeStore`. Views
  read the stores directly and mutate state only through store methods.
- **Outbound:** mutation builders in `Core/Mutations` build request objects;
  `App/Runtime/ServeMutationClient.swift` sends newline-delimited runtime
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
(`RowLook`, `OutlineLook`, `ActionBarButtonLook`, `PlateBand` in
`Core/Rendering/InteractionLook.swift`) and draws it; it never picks a palette
colour by state itself. The colours are `StateColor` cases, which `AppPalette`
builds its matching entries from (`SharedUI/Theme.swift`).

The mouse highlights, the keys move the cursor, and a click acts. The pointer
shows the hover look (`RowLook.hovered`: a 1pt `line` outline, no fill, text
and icon unchanged; `controlBorder` on a raised surface, where `line` barely
shows; every cursor and selection look is filled, so the two never read alike)
on the row under it, via `stateRow`, and moves no list's cursor or
selection. Return, Tab and Save
commit the keyboard cursor; a row the pointer only crossed needs a click. The
one exception is the tracker while it has the keys: hover moves its cursor
(`highlightOnHover`, real pointer motion only), and its list doesn't scroll to
a cursor the pointer moved, and drops a key scroll still queued
(`PointerCursor`). A pill tab is already `item`
filled, so tabs have no hover look.

A region has the keys while it's focused and no modal is drawn
(`NavigationStore.hasKeys`); its focus looks follow that. Inside the dock only
the focused panel has them (`NavigationStore.hasKeys(_: DockPanel)`). When the
user leaves a region or panel, a selection that lasts (a tab row's) and a
cursor whose design draws an unfocused state (the artifact list's) stay one
step dimmer; a pure cursor with no lasting selection and no designed unfocused
state (the tracker's, Version Control's: `RowLook.cursor`) hides, and shows
again where it was when the keys come back.

| Element | State | Look |
|---|---|---|
| Pick-to-open row (artifacts, dropdowns, filter suggestions) | rest | no fill, `textBody` #ADBAC7, icon tile border `line`, icon and meta `textMeta` #8D9AA8 |
| | highlighted, area focused (`RowLook.highlighted`) | `item` fill, `textSelected` #C4D0DC, icon tile border `controlBorder`, icon `textSelected`, meta `textMetaHighlighted` #9DA7B1 |
| | highlighted, area unfocused (`RowLook.highlightedUnfocused`) | `item` fill, `textBody` text and icon, icon tile border `controlBorder`, meta `textMeta` #8D9AA8 |
| | missing file (`RowLook.missingFile`) | the row's look with a `warn` icon |
| | marked for deletion (`MarkLook`) | `accent` diamond in the row's left gutter |
| Any row | under the pointer (`RowLook.hovered`) | 1pt `line` outline, no fill; text, icon and meta as at rest |
| Row on a raised surface (the Worker Log filter's dropdown, drawn in `item`) | rest (`RowLook.raisedRest`) | no fill, `textBody`, icon and meta as at rest |
| | highlighted (`RowLook.raisedHighlighted`) | `line` fill, one step above the surface (an `item` fill would vanish on it), `textSelected`, meta `textMetaHighlighted` |
| | under the pointer | 1pt `controlBorder` outline, no fill; text, icon and meta as at rest |
| Lasting-selection row (the Quest Log) | selected (`RowLook.selected`) | `item` fill, **bold** `textSelected` |
| Tab (agent tabs, Session/All, Settings sidebar) | rest (`OutlineLook.tabRest`) | `line` outline, `textBody` |
| | selected (`.tabSelected`) | `controlBorder` outline, `textSelected` |
| | selected, area unfocused (`.tabSelectedUnfocused`) | `controlBorder` outline, `textBody` |
| Text tab (the Worker Log's worker tabs) | rest (`TextTabLook.rest`) | no outline or fill, `textMeta`, regular |
| | under the pointer (`.hovered`) | `textBody`, regular |
| | selected (`TextTabLook.tab`) | **bold**, the selected pill tab's label colour: `textSelected` while the panel has the keys, `textBody` without them; the pointer adds nothing |
| Field | rest / focused (`.fieldRest` / `.fieldFocused`) | `line` / `controlBorder` border (`fieldChrome`) |
| Dock panel frame | rest / focused (`.frameRest` / `.frameFocused`) | 2pt `lineSoftSubtle` / `controlBorder` |
| Icon button (dock top bar) | rest / under the pointer | `RowLook` icon: `textMeta` / `textSelected` |
| Action bar button (`ActionBarButtonLook`) | rest / active (the tracker or the dock panel it opens shows) / under the pointer | `item` fill and `line` border in every state; icon `textMeta` / `textBody` / `textSelected` |
| | toggle on (caffeinate) | icon unchanged; a 2pt `brassActive` inner glow at 15% and the tracker's working spinner (`SpinnerRingView`) turning round the 1pt border |
| Tracker plate | cursor, while the tracker has the keys (`PlateBand.showsCursor`) / under the pointer / recolouring | `textSelected` / `controlBorder` / `accent` band; no band otherwise |
| | attached: the session open in the terminal (`TrackerAttachedDot`) | a 5pt dot (`Space.row`) in the project colour (`TrackerNameplateColor.barLightness`, the project name's and side diamonds'), its centre `Space.item` left of the disc's left edge and level with the disc's centre; no shadow, no band, hit shape, layout or number change |
| Shell row (the tracker's shell section) | rest (`RowLook.shellRest`) | no fill, title and glyph `textMeta`, glyph disc `item` rim (a filled row's disc takes the look's own rim) |
| | under the pointer | the hover look (1pt `line` outline), on a resting row only |
| | keyboard cursor, while the tracker has the keys (`RowLook.shellCursor`) | 1pt `controlBorder` outline inside the row, no fill, text and glyph as at rest, regular weight |
| | the viewed shell (`RowLook.selected`) | `item` fill, **bold** `textSelected` |
| | the cursor on the viewed shell (`RowLook.shellSelectedCursor`) | the fill and bold, plus the `controlBorder` outline |

- The attached dot follows the attached session, never the cursor or the pointer. A master's or an expanded worker's own
  plate carries it; a worker shown only as a collapsed circle puts it on its master's plate; a shell carries none (its
  filled, bold row marks it), and neither does nothing attached. It sits in the list's leading gutter (a master's reaches
  12.5 left of its row), drawn outside the plate's silhouette layers, which clip at their margin.
- Bold means selected and appears only in a lasting-selection list, a text tab row's selected tab or a selection chip's value. Artifacts
  have no selected state: picking one opens it.
- Shells are not plates: every shell, tmux and orphan row leaves its repo group for the shell section pinned under all
  the plates (`TrackerShellSection`, drawn by `TrackerShellRow`). A shell's own display colour tints its title in every
  state; none leaves the state's text colour.
- Dividers inside rows are `line` in every state.
- Brass and glow mean "on", for toggles only. One gold, `accent` #D7B13D, for
  titles, project headers and marks; never for selection or focus.
- Shadows come only from an elevation token (`Elevation` in `SharedUI/Theme.swift`), never numbers at the call site;
  each is a black drop shadow, and a shadow drawn inside a clip is a bug (draw it outside, as `scoopedPanel` and
  `ScoopedLayerChrome` do). `raised` (black 35%, blur 4, 1.5 down): tracker plates and their discs, and every
  dropdown (`SuggestionDropdown`). `panel` (30%, blur 12, 4 down): the dock's panels, the action bar header and the toast. `modal` (45%,
  blur 30, 10 down): every in-window modal, the Quest Log included. An inner shadow, the one kind that belongs inside
  its clip, is a `Recess` token in the same file (`portrait`: 3 deep, blur 1, black 20%, the sheets' portrait discs).
  Panel, dock and toast borders are 2pt
  `lineSoftSubtle` (`ScoopedRectangle.borderWidth`). A dock panel's frame lifts to
  `controlBorder` while it has keyboard focus and no modal is drawn, and only the focused panel's does
  (`OutlineLook.frame`, `ShellFocusCoordinator.updateRegionKeys`). Pressed is
  0.8 opacity; disabled is window fill with `item` border and label (the shared
  button styles).
- Use the shared components: `stateRow` for rows (`ListRow` for the tracker's
  plates), `PillTab`/`PillTabRow` for tabs (no icon: no disc),
  `fieldChrome`/`FormTextField` for fields, `FilterBar` for filter fields,
  `SuggestionDropdown` for every dropdown and suggestion list (`dropdownChrome`
  is its box, for a dropdown that isn't a list of suggestions), `FilterChip` for
  filter chips (`ClearableChip` for a selection with an x), the `AngledButton`
  styles for buttons.
- The Worker Log's filter (`WorkerLogFilterPanel`) is a dropdown of the Action
  checkbox rows on `dropdownChrome(.raised)`: it stands in front of the dock, so it is
  lighter than it (`item` fill, `line` border, radius 4.5), and its rows take the
  raised looks (`RowLook.raisedPick`). A checked box's mark takes the row's text
  colour. Ticking every box is an ordinary selection (the chip names all five
  and only its x clears it). The Action ticks are app-wide: one selection shared by
  every master, kept when the attached master changes (`WorkerChatStore`, in
  memory only, so not across restarts). The dropdown is as tall as its rows, up to its panel's height less
  the 5 under the bar and the 20 inset below (the tab row's room when there is one), and scrolls past that with the
  cursor kept in view: with Version Control above, the bottom panel is shorter
  and it scrolls sooner, never reaching behind it. The filter belongs to the
  bottom panel: its icon sits in that panel's top bar, shows only while the log
  is attached to a master and toggles the dropdown; `f` and the dropdown's keys
  work only while that panel has the keys, and the keys leaving it (to Version
  Control, the tracker, the terminal or a modal) close it. A click anywhere else
  on the dock, either top bar included, closes it too. Its one chip reads "Action:" in
  `textMetaHighlighted` at regular weight, then the ticked names in `textBody` **bold** (the
  current selection is what bold means), comma-separated in the dropdown's order, which is
  alphabetical (Cast, Item, Message, Status, Summon; `WorkerLogAction`, `WorkerLogFilter.actionSummary`), and grows with them; with nothing attached the log is
  blank, chip included. It sits 5 under
  the top bar and stays there whatever the feed is doing (first read pending or
  failed, empty, lines). The feed fades in under its header, the bar and the
  chip when there is one, over its top 20 (`WorkerChatMetrics.topFadeHeight`,
  the Quest Log's overflow mask), so lines scrolled up under it are never cut
  hard, and a feed at its top starts its first line 20 under the header, where
  the fade ends, with or without the chip.
- The Worker Log's worker tabs (`WorkerLogTabRow`, from `Tabs (Simple).svg`) are pinned to the bottom of the panel: All, then
  one text tab per worker of the attached master in tracker order (`WorkerChatStore.workers`), JetBrains Mono 12pt (the feed's chat
  font, `AppFonts.workerTab`), a diamond (the `line` colour) between them with `Space.row` on each side: tab, 5, diamond, 5, tab. They take a `TextTabLook`. One tab is
  selected (`WorkerLogFilter.workerID`, nil for All): All shows every worker's lines, a worker's tab only that worker's,
  and it ANDs with the Action ticks. The tab is kept per master (it names that master's workers; in memory only), unlike
  the Action ticks, and falls back to All when its worker goes away. Hidden while the master has fewer than two workers (All plus one tab adds nothing;
  `WorkerChatStore.showsTabs` is the one predicate for the view, the dropdown's room and the keys), and when the row
  goes away the selection falls back to All, a remembered tab included. A click selects a tab; `[` and `]` step to the previous
  and next, wrapping as the Settings tabs do (`Keymap.Action.previousTab` and `nextTab`, handled where `f` is), with the dropdown open or closed,
  and work only while the bottom panel has the keys and the row shows (otherwise they pass through). The feed ends where
  the row begins; the row is `ControlHeight.compact` (25) high, the line of text centred in it (baseline 17 down, a 12pt line
  being too tall for the 15-high chip), and ends 10 above the panel's bottom edge, which puts the tabs' baseline 18 over it
  and the last feed line's ink 30.5 over their caps (the user's mock, at 10pt, had 20 and 32). Tabs too many for the
  panel scroll sideways with no scroller, in a view 35 in from the panel's edges (`WorkerLogTabMetrics.sideInset`: the
  bottom corners' scoop radius, 25, plus `Space.item`), so every tab, clipped or not, stays 10 clear of the scoop; a side
  with hidden tabs fades out over 20, as the feed's top does. A change of selection scrolls it to the middle. The empty state stays centred in the room above the row.
- Nothing to list is one icon, `EmptyState`: a single `Token.Size.emptyIcon` (40) tray in `textMeta`, centred in the
  section the list would fill, with no text, hint or command. Every dock panel (the artifact list under its tabs, the
  artifact viewer, the Worker Log, Version Control), the tracker and the Quest Log's page draw it; the page passes the
  parchment ink instead. The Worker Log draws it only once its first read came back whole and empty, or when
  its filter or worker tab hides every line (`WorkerChatStore.isKnownEmpty`, decided in Core; the chip above it stays, with its x, and the tabs under it when they show);
  while that read is pending, failed or partial it is blank, and its `readNotice` says what failed. So does the terminal pane once its session has ended (`TerminalShellView.showEnded`, only
  after the viewed session is deleted with nowhere to switch to); every attach clears it first, and while a session attaches
  the pane shows the skeleton veil. A message the user needs (a missing file, an artifact kind the build can't show, an
  incompatible backend) is a `StatusMessagePane`, which an empty list never is.
- A list still loading is a skeleton: a ghost of the real thing, in its own shapes and palette (the tracker's is
  `TrackerNameplateBackground`'s plates with no text, status or portrait, the Settings picker's is `fieldChrome`, the
  terminal's is `SkeletonBar` lines), breathing in `SkeletonPulse`. That is one Core Animation fade of the layer SwiftUI drew
  the ghost on, `SkeletonMotion.period` (1.6s) each way on `Motion.breathingTimingFunction`, only while in a window, still
  under Reduce Motion (read through `Motion.reducesMotion`, not SwiftUI's environment, so the self-tests' override applies):
  SwiftUI never animates a skeleton, so nothing redraws while the terminal shares the main thread.
- Dock titles (Artifacts, Worker Log, Version Control, an open artifact) are title case in
  `accent`, 14pt bold, on the top bar's baseline 25 down. While a refresh the user asked for (`r`) is under way, Version
  Control's title bar shows the working spinner, the tracker's own (`SpinnerRing`, `WorkingSpinner.period`), as a 15pt
  ring `Space.item` past the title, on the icon line, taking no room so the centred title never moves. Core decides it
  (`PullRequestStore.isRefreshing`): from the key to the daemon's reply (`pr.refresh` with `wait`), for at least one turn
  and never past 30s; a second `r` meanwhile sends nothing, and the daemon's background polls never show it. It is Core
  Animation only, runs only while on screen, and holds still and full under Reduce Motion. No hint or footer text.
- The action bar is a header over the terminal column (`Main Chat Header.svg`): a 50pt (`ControlHeight.row`) scooped
  panel at radius 13, its top level with the tracker's and the dock's (`sideCardInset` down), `Space.section` from the
  tracker's plates and the dock, or from the window's edges when they're hidden, with the terminal's text starting
  `Space.section` under it. `ShellSplitLayoutPlanner` gives its frame (`headerFrame`) and `MainSplitView` lays it out
  and animates it with the panes. Its 30pt buttons sit `Space.item` from its top and bottom and `Space.section` in from
  its ends: the tracker toggle alone at the leading end; New Session, Quest Log and Settings, then Artifacts, Worker Log
  and Version Control at the trailing end, 1 apart in a group and `Space.item` between the groups; caffeinate
  `Space.section` past them (`ActionBarMetrics`). Its empty space drags the window. Toasts sit `Space.section` above the
  window's bottom edge.
- The dock is two stacked scooped panels, 20 apart (`DockColumnLayout`): Version Control on top at a fixed 300, and
  under it the artifacts or the Worker Log. Each has its own title and close button, and either shows alone
  (it then fills the dock). `DockState` keeps their visibility app-wide; ⇧⌘K and ⇧⌘J move the keys between them (all
  navigation is ⇧⌘). An open modal owns ⇧⌘H/J/K/L: J/K move its vertical cursor or field, and H/L move a horizontal
  choice when it has one; otherwise they do nothing inside the modal. With no modal, H/L focus shell regions and J/K
  are the dock's own only while the dock has the keys and both panels show (`NavigationStore.commandChordRoute`, which
  uses `dockPanelKeyRoute`; pressing the focused panel's key does nothing). From the terminal or tracker, or in a dock
  with one panel, J/K pass through to the focused responder, so Ghostty receives its own ⇧⌘J binding
  (`write_screen_file:paste`); the View menu items are enabled only for the dock route. With no modal, ⇧⌘R toggles
  Version Control from the monitor before the terminal; while a modal is drawn, app shortcuts are consumed or disabled,
  except text editing, Quit and modal commands the top modal accepts (the Quest Log permits its toggle and New Quest as
  a child). A panel appearing or going away fades and slides 10pt while the other grows or shrinks, over the standard
  motion step and only once (`DockPanelMotion`; Reduce Motion skips it, see "Motion"): never an animation that keeps
  running, as the terminal shares the main thread.

`StateRulesScanTests` (in the logic-test runner) scans `app/Sources/App` and
fails on a raw colour outside `Theme.swift`, a `StateColor`/`textSelected`
outside the token layer, `brassActive` or `ActionBarButtonLook` outside the action bar, a
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
own height as an `svg…` constant and scales to the control's.

Portraits sit on 5s too: the master's disc spans 0-50 and the worker's 20-60 in
their rows, and plate text starts `Space.row` past the disc's round edge (55,
65; the side diamonds don't count). The selected-session panel's text starts
`Space.item` past its disc (80). Logos are 0.6 of their disc (30, 24, 15),
canvases and icon, logo and mark sizes are lengths like any other. A plate disc with a class portrait carries its
agent's logo in a 25pt badge (logo 15), as big as a collapsed worker's circle, whose edge hangs `Space.row` outside the
disc on the left and below it (`TrackerPlateDesign.badgeOverhang`); the sheets' title row is a 40pt portrait disc, `Space.item`, then the 35pt field.
A shell row is 35 high (`ControlHeight.field`) and as wide as the 260 column, flush with the plates, stacked with no gap
(the tracker mock's layout, not Shell Session.svg's inset and spaced rows), with a 25pt disc (`ControlHeight.compact`) 10
in and the title 10 past it. The shell section is pinned to the bottom of the tracker column (`verticalPadding` from its
edge), as tall as its rows up to `TrackerShellMetrics.maxHeight` (175, five rows) and scrolling inside itself past that;
the plates scroll in their own list in the space above it, which shrinks to make room and ends
`TrackerListMetrics.shellClearance` (`Space.group`) over the section. Each scroller sees only its own rows' cursor
(`plateCursorID` / `shellCursorID`), and a cursor the pointer moved scrolls neither (`PointerCursor`).

Not spacing, so free of the rule: text baselines and line heights, a glyph's
optical nudge, radii and stroke widths, 0/1 spacers, and `svg…` lengths in an
SVG's own coordinates: path data, and an art's own size where no uniform scale
lands both sides on 5s. A design value that
isn't on 5s is snapped to the nearest 5 or redrawn onto 5s, never kept with a
marker.

`SpacingRulesScanTests` (in the logic-test runner) enforces it and must find no
breaks:

- **raw-spacing**: no layout number in a view (`.padding`, stack and grid
  `spacing`, `.frame` sizes, `Spacer(minLength:)`, `EdgeInsets`, constraint
  constants, `.offset`, `.position`), except 0 and 1 and lines inside an `enum`
  named `*Metrics`, `*Layout` or `*Design`. A number in a ternary branch, added
  to a step (`Space.item + 3`) or scaling one (`Space.item * 1.3`) counts;
  halving or doubling (`2 * border`, `/ 2`, `* 0.5`) and an inner call's own
  arguments don't. A `//` inside a string is no comment.
- **scale-restated**: a gap/inset/spacing/margin/padding/gutter constant of 5,
  10, 20 or 40 names its `Space` step.
- **off-rhythm**: a CGFloat constant or default named as a length (gap,
  spacing, margin, padding, gutter, pitch, indent, inset, clearance, offset,
  height, width, side, size, lead, trail, nudge, origin; x and y for a static or
  metrics constant, not a local in path code) is a multiple of
  5, and so is each number of an `NSSize`/`CGSize` assigned to an inset,
  padding, margin or gap, metrics enums included. Only names that say they aren't
  spacing are exempt (`baseline`, `lineHeight`, `radius`, `stroke`, `border`,
  `ring`, `glow`, `pointSize`, `font`, a `glyph` nudge, and `svg` coordinates).

The scan reads lines, so `testRenderedSpacingStaysOnTheScale` (a
`--run-logic-tests` self-test) measures rendered pixels for what it can't see:
the artifact rows' 45pt pitch and a form's fields 10 under the header band and
20 apart.

## Motion

Every one-shot transition takes a step from the motion tokens, so the app moves at two paces on one easing. A view never
states a duration or a curve. Core holds the numbers (`MotionStep`, `MotionEasing` in `Core/Rendering/Motion.swift`), the
App target the forms each framework takes (`Motion` in `SharedUI/DesignTokens.swift`).

| Step | Seconds | Role |
|---|---|---|
| `MotionStep.fast` | 0.12 | a small change: the modals' fade-out, the toast showing, a page swap or overflow cue in the Quest Log, the artifact rows' select-mode toggle, the cast bar's fade |
| `MotionStep.standard` | 0.18 | a panel, modal or layout move: the modals' fade-in, the toast hiding, the split view's panes, the dock's panels (`DockPanelMotion`), the tracker's expand/collapse and cast-row open/close, the Quest Log's unroll, the worker chat's glide and arrival fade, the attach veil, the selected-session panel's icon fade, the status ring's crossfade, exit sweep, flash and exit fade, the cast bar's finish flash |

- **One easing:** ease out, quick at first and settling, as the cubic Bézier (0, 0, 0.58, 1), the system's own `.easeOut`.
  `Motion.timingFunction` is its Core Animation and AppKit form, `Motion.animation(_:after:)` its SwiftUI form, and
  `MotionEasing.eased` the same curve for a transition stepped by hand (the dock column).
- **One breathing easing**, for a continuous animation that eases up and back (the cast bar's and the status ring's
  pulse): ease in and out, the Bézier (0.42, 0, 0.58, 1), the system's `.easeInEaseOut`. `Motion.breathingTimingFunction`
  is its Core Animation form (numbers in `MotionEasing.breathingControlPoints`). A one-shot never takes it, and a pulse
  takes no other curve; a new continuous animation (a skeleton's breath) uses it too.
- **Reduce Motion is read once**, in `Motion.reducesMotion` (a var, so a self-test can set it). Under it every step is 0:
  `Motion.animation` returns nil (the change lands at once), `Motion.configure` gives an AppKit context no duration, and
  Core Animation code checks `Motion.reducesMotion()` and adds no animation (a duration of 0 means "the default" there). A
  transition is skipped, not shortened; a fade is skipped too. A Core Animation view that already gets `reduceMotion`
  from the SwiftUI environment (the status ring, the cast bar) skips on that and takes its step lengths from
  `Motion.duration`; the ring's exit and crossfade are skipped under it, so the ring just goes. The logic-test runner
  starts every case with it off.
- **Sequencing** is a step too: `Motion.animation(.standard, after: .fast)` starts one step late (the Quest Log's paper
  unrolls as the modal's fade-in ends, then the ink follows).
- **One-shot only.** The terminal shares the main thread, so a transition runs once and nothing keeps running. Prefer
  Core Animation; SwiftUI's `withAnimation` and `.animation(_:value:)` are fine for a short one-shot. Continuous
  animations (`SpinnerRing`/`WorkingSpinner`, the cast bar's and status ring's fill, pulse and shimmer, the skeleton
  pulses) keep their own periods, named as a `period` or a duration learned at runtime, and are outside the steps. An
  animation that ends, even one of those views' (a flash, an exit, a crossfade), takes a step.
- **A new transition** picks `fast` or `standard`; a step is added to `MotionStep` only for a new pace the app doesn't
  have yet, never a one-off number.
- **Selected-session panel:** the disc's icon is the class portrait; a shell, tmux or orphan session shows the shell
  row's terminal glyph (`ShellTerminalGlyph`, scaled with the disc, `textMeta`); no class, or nothing attached, leaves the
  disc empty. The icon fades in once when the attached session or its portrait changes, over `standard`; the old icon goes
  at once and the first draw doesn't fade. It is one Core Animation opacity animation (clear to full,
  `Motion.timingFunction`) on the icon's own layer, run by the render server, so SwiftUI redraws nothing for it
  (`IconFade`, a hosting view like `SkeletonPulse`'s; no `.id`/`.transition` re-creation per switch). The disc is drawn in
  layers so only the icon fades: the base (with the strips, one Canvas), the icon's one `IconFade` layer, and the
  overlay (a Canvas). The icon key is empty when the disc has none, and an empty key never fades, so a switch fades only
  an icon coming in: one fade a switch that brings an icon in (from an empty disc too), none to an empty disc. A change
  with no window or the same key adds no fade; a new key (an empty one too), leaving the window, or any update under
  Reduce Motion drops one still running.

`MotionRulesScanTests` (in the logic-test runner) scans `app/Sources/App` and fails on a break:

- **raw-duration**: a number literal as an animation's `duration:` / `.duration =` / `.delay(` /
  `setAnimationDuration(` (0 is allowed), or a SwiftUI curve built outside the token layer (`.easeOut`, `.snappy`,
  `.spring`, `.default` … in `withAnimation`, `.animation` or an `Animation` value; they carry a default duration of
  their own); a repeating SwiftUI animation is no exception.
- **duration-constant**: a constant or local whose name ends in a timing word (duration, delay, time, fade, crossfade,
  sweep, flash, transition, glide, unroll) assigned a non-zero literal, typed or inferred (`let fadeTime = 0.4`); it
  comes from a step. A continuous animation names its `period`.
- **raw-easing**: any `CAMediaTimingFunction(` (by name or control points) or `.timingCurve(` outside the token layer.
  A one-shot takes `Motion.timingFunction`, a pulse `Motion.breathingTimingFunction`. There is no exception by file or by
  neighbouring line, and no file list: a finite animation and a continuous one are held to the same three rules, and a
  continuous one passes them by naming its `period` and taking the breathing token.

The scan reads lines, so a duration passed through a helper's parameter isn't seen.
`testSelectedSessionPanelFadesItsIconInWhenTheSessionChanges`
hosts the panel in an off-screen window and asserts the fade is a Core Animation opacity animation on the icon's layer
(from clear to full, `standard`, `Motion.timingFunction`, once), that its presentation layer starts clear and reaches full
opacity, that exactly one fade runs when an icon comes in (class to class, class to shell, shell to class, empty disc to
class), that no view is re-created, that the disc ends as drawn fresh, that a switch to an empty disc drops a fade still
running, and that the first icon, an unrelated edit, a switch to or between empty discs, a view outside a window, one that
left it and Reduce Motion show none. `cacheDisplay` draws the model layers, so it cannot see a Core Animation fade; the
test reads the presentation layer's opacity, and
`RENDER_ONLY=selected-session-fade-gif QUESTMASTER_ANIMATION_SLOWDOWN=6 … --render-preview <dir>` records it frame by
frame from the presentation layers (`recordAnimation(…, capturesLayers: true)`; `QUESTMASTER_ANIMATION_SLOWDOWN` stretches
every step in DEBUG builds so the recorder can sample it).

## Testing conventions

- **Go:** stdlib `testing` only (no testify), table-driven, `t.Parallel()`,
  `t.Helper()` on helpers. State uses a `t.TempDir()` store; tmux is mocked via a
  `Runner` func. Goldens live in `testdata/` dirs. Tests that resolve the state
  root must set `QUESTMASTER_STATE_ROOT` to a temporary directory; the resolver
  rejects the live root in test binaries.
- **Swift:** Core-only, via a custom runner in
  `app/Tests/QuestmasterLogicTests/main.swift` (no XCTest). Add a pure-Core suite
  by appending `XxxTests.run()` there. The runner also spawns
  `Questmaster --run-logic-tests` and asserts a non-zero
  `Questmaster self-tests: ... passed` line. **UI is not unit-tested**; verify it
  by building and by manual/bench checks. `Questmaster --render-preview <dir>` (DEBUG; `RENDER_ONLY=name,...`,
  `RENDER_SCALE=2`) renders the fixtures off-screen. `RenderPreview.renderView` hosts each in a frame-based container, not
  as the window's content view: a content view's constraints give the window a minimum size, and a hosting view nested
  in them (a dock panel's body) reports its content's minimum, wrapped text at zero width, so a render came out taller
  than asked.

## Workflow

- Keep `internal/agent/prompts/` to Questmaster role identity, session mechanics,
  and CLI behavior. Delegation thresholds, reviewer cadence, model preferences,
  and general writing or repository practices belong to the user or applicable
  project instructions, not the injected session prompt.
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
