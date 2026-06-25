# Questmaster.app — Architecture Modernization Plan

Status: **In progress — foundation landed (Phases 0, 1, 5); the SwiftUI Tracker is now
the default/only tracker path and the old AppKit tracker path plus renderer gate are
removed; Phases 3–4 not started**. This is a planning doc capturing the overall idea.

## TL;DR

Three things we keep circling back to are actually **one coordinated refactor**:

1. **The missing shared state/command layer** — `AppDelegate` (~985 lines) is a god
   object because there is no observable model between the data clients and the views,
   and tracker-specific commands still live in view callbacks instead of one
   platform-neutral interaction layer.
2. **A pane-by-pane SwiftUI port** — the tracker has moved to SwiftUI, while the dock,
   quest viewer, new-session modal, shell, and terminal integration still use AppKit
   where that remains pragmatic.
3. **A design-token system** — colors/fonts/metrics are partly centralized
   (`AppPalette`, `AppFonts`, `ShellMetrics`) but radii/insets and a second metrics
   struct are scattered as inline literals, and the palette duplicates state
   classification that already lives in `QuestmasterCore`.

Doing any one alone gets ~half the value. The keystone is UI-independent state and
command logic, not SwiftUI itself. `RuntimeStore`, `NavigationStore`, and the tracker
command/effect layer are the first step: they keep runtime/navigation state observable
and keep tracker actions testable while SwiftUI remains a thin renderer.

## Why these are coupled

- `AppDelegate` is a god object *because* there's no observable model. Observation fixed
  snapshot propagation, and tracker activation/delete/recolor decisions now live in
  Core command/effect types. Keep moving side-effect orchestration out of
  `AppDelegate`; SwiftUI views should adapt input events and render shared state.
- Design tokens only pay off once views read from a shared semantic layer. A SwiftUI
  rewrite touches every view body anyway — that's the cheapest moment to swap inline
  literals for tokens, so the token work should *ride along* with each pane's port
  rather than be a separate sweep.

## What carries over for free

- **`QuestmasterCore` stays pure and unchanged.** Models, state machines
  (`NavigationLogic`, `NewSessionFormModel`, `TrackerRecolorState`), mutation builders,
  selection/cursor logic — all UI-agnostic value types. They become the spine of the
  shared state/command layer verbatim.
- **`RuntimeSnapshot.apply(_:)`** already *is* the merge logic. We delete the plumbing
  around it, not the logic itself.
- **The vendored `GhosttyTerminalRepresentable.swift`** already exists, so the terminal
  is SwiftUI-ready as an `NSViewRepresentable`.

## Target architecture

```
QuestmasterCore (pure: models, state machines, mutation builders, tracker decisions)
        ▲
Stores + interaction layer (@Observable stores, tracker commands, coordinators)
        ▲                       owns UI-independent decisions; emits side-effect intents
Thin shells (AppKit and SwiftUI renderers; adapt events, no duplicated branching)
        ▲
App/window services + AppKit islands (terminal, rich-text quest viewer)
```

`AppDelegate`'s current responsibilities decompose as:

| Today (in `AppDelegate`) | Becomes |
|---|---|
| `snapshot` + `apply(update)` + `renderSnapshot()` | **`RuntimeStore`** (`@Observable`, single source of truth) |
| `AppNavigationState` + focus/toggle methods | **`NavigationStore`** (wraps the existing pure state machine) |
| Tracker selection/recolor/delete callbacks | **Tracker interaction/command layer** (shared state + typed effects) |
| `sendMutation`, `switchTerminal`, `activateTerminalSession` | **`SessionCoordinator`** (orchestration over services) |
| `ServeProcess` / `ServeClient` / mutation client lifecycle | **services**, protocol-bound, injected into stores |
| menus, signal handlers, confirmations/status, traffic-light geometry, terminal host | thin `NSApplicationDelegate` shell + side-effect routing |

Inbound path collapses from "client → `apply` → `renderSnapshot` → manual fan-out to
3 views" into roughly:

```swift
@Observable final class RuntimeStore {
    private(set) var snapshot: RuntimeSnapshot
    func handle(_ update: RuntimeUpdate) { snapshot.apply(update) }  // views re-diff automatically
}
```

Command path collapses from "view callback → AppDelegate/view-specific branching →
service call" into roughly:

```swift
view event -> TrackerCommand -> TrackerInteraction -> TrackerEffect -> side-effect router
```

The effect executor may live in `AppDelegate` temporarily, then move behind
`SessionCoordinator`/service protocols. It should not own tracker-specific branching.

## Workstreams

### A. View-model / store extraction (foundation)
- Extract `RuntimeStore`, `NavigationStore`, and a `SessionCoordinator` out of `AppDelegate`.
- Define the data clients behind protocols already half-present (`RuntimeClient`,
  `ServeMutationSending`, `ServeDirectorySuggesting`) and inject them — enables tests
  and previews with fakes.
- **Can land entirely under existing AppKit** (views still get `setSnapshot()`, now from
  a store). This de-risks everything downstream and ships value even if SwiftUI stalls.

### B. Tracker command/interaction extraction
- Extract the tracker command surface once: selection movement/recovery, activation,
  jump-to-attention, delete, inline recolor, focus handoff, confirmations/status, and
  mutation request construction for supported tracker commands.
- Relay, broadcast, and spawn have been removed from the native tracker surface instead
  of ported. Keep them out of tracker work; backend CLI/serve support may remain for
  orchestration and automation.
- Treat attach-to-quest as out of scope for tracker parity and typed prompt work because
  the quest area is going to be overhauled. Reevaluate it with that quest work rather
  than fixing or porting it during tracker work.
- Reuse existing Core state machines/builders (`RepoListSelection`,
  `TrackerActivationDecision`, `TrackerRecolorState`, `TrackerRenderer`,
  `ServeMutationRequests`, `DestructiveConfirmation`) rather than translating AppKit
  branches into SwiftUI branches.
- The shared layer should own tracker state that is currently view-local
  (`TrackerRootView` `@State` selection). It should emit typed effects for side
  effects: send mutation, show confirmation/status, switch terminal, focus pane/control.
- Keep SwiftUI tracker behavior on this layer. The old AppKit tracker is no longer a
  compatibility target.

### C. SwiftUI port (pane by pane)
- Before adding SwiftUI behavior, extract the pane's UI-independent decisions/actions.
- Host SwiftUI inside the existing `NSWindow`/split via `NSHostingView`; migrate one
  region at a time behind the same stores and command layer.
- Remaining suggested order:
  1. **Dock** quest board
  2. **New Session modal**
  3. Status chrome / top bars
- **Keep as AppKit islands:** the GhosttyKit terminal and the `ItemViewer` rich-text
  quest viewer (interactive `NSAttributedString` / `NSTextView`).
- **Deployment target: bumping to macOS 14** (decided — see below). This unlocks
  `@Observable` and `.onKeyPress`, so the focus model can be done natively without a
  fallback AppKit key-routing layer.

### D. Design tokens
- Today: `AppPalette` (colors), `AppFonts` (fonts), `ShellMetrics` (some insets) exist,
  **but**: corner radii and many insets are inline literals (`cornerRadius = 7/8/3`,
  `columnWidth`, etc.) and there's a *second* metrics struct inside
  `RepoSectionedListView`. Consolidate into one semantic token layer:
  - **Color**, **Font**, **Spacing/Radius/Size** token sets with semantic names
    (`Token.Color.panel`, `Token.Radius.card`, `Token.Spacing.rowInset`).
  - Expose **both** `NSColor`/`NSFont` (for AppKit islands) and `Color`/`Font` (SwiftUI)
    from one source of truth so the two worlds never drift during the migration.
  - Fold token adoption into each pane's port (cheapest when the view body is being
    rewritten anyway) rather than as a separate sweep.
- **Related cleanup to fold in:** `AppPalette.role(_:)` / `.status(_:)` / `.agent(_:)`
  re-implement state classification via stringly-typed `switch`es that *duplicate*
  `TrackerStatusClassifier` in Core. Move the classification to Core (typed), let the
  token layer map a typed status → color. Kills a stringly-typed seam and a duplication
  in one move.

### E. Other smells worth folding in (decide per-item; avoid scope creep)

**Fold in — they co-locate naturally with A/D:**
- **Duplicated socket transport.** `UnixSocketServeClient` (streaming),
  `UnixSocketMutationClient` (one-shot), and `ServeProcess`'s address helper each
  reimplement connect / read-line / `sockaddr_un` framing. When we put clients behind
  protocols for the stores (workstream A), unify the low-level transport into one
  `UnixSocketTransport` and build both clients on it.
- **Silent lossy decoding.** `RuntimeDecoding` drops malformed server items to stderr
  with no surfaced signal. The new `RuntimeStore` is the natural home for an observable
  `decodeWarningCount` / last-error that the UI can show — backend drift becomes visible.

**Tempting but keep separate (different risk profile / not on this critical path):**
- **Main-thread blocking:** `loadLoginShellEnvironment()` spawns a login shell
  synchronously at startup (~up to 2s); `ItemViewer` builds large attributed strings on
  the main thread. Real perf wins, but they live in the AppKit islands we're *not*
  rewriting first — track separately.
- **Temp tmux startup dirs** in `NSTemporaryDirectory()` are never cleaned up — trivial
  hygiene fix, can ride along opportunistically but isn't part of this arc.
- `validateMenuItem` returns `true` in every branch (dead logic) — trivial, sweep anytime.

## Phasing

1. **Phase 0 — Proof slice.** Extract `RuntimeStore` + `NavigationStore` from `AppDelegate`
   and rewire **Tracker only** to read from them, *still in AppKit*. Compiles, tests pass,
   no behavior change. Validates the decomposition before committing to SwiftUI.
   - **Done:** `RuntimeStore` + `NavigationStore` added to
     `QuestmasterCore` (pure, unit-tested in the logic harness via `RuntimeStoreTests` /
     `NavigationStoreTests`). `AppDelegate` now owns the snapshot, serve-connection state,
     terminal-session id, and navigation through the stores instead of bare properties.
     The tracker observes `RuntimeStore` directly, so `renderSnapshot()` no longer pushes
     into the tracker. Behavior is intended to be unchanged.
2. **Phase 1 — Token foundation.** Stand up the unified token layer (dual NS*/SwiftUI),
   migrate `AppPalette`/`ShellMetrics`/inline literals behind it. Move status/role/agent
   classification into Core.
   - **Done (pending macOS build):** `Package.swift` bumped to macOS 14. Added
     `Token.Radius` / `Token.Spacing` plus `NSColor.swiftUI` / `NSFont.swiftUI` bridges
     (`DesignTokens.swift`); pointed `ShellMetrics` / `ShellPillMetrics` and the scattered
     inline corner radii at them. Added typed `AgentKind` / `SessionRoleKind` /
     `QuestStatusKind` in Core (`DisplayClassification.swift`, unit-tested) and made
     `AppPalette.agent/role/questStatus` delegate to them.
   - **Not yet done:** full inline-literal sweep across every view, and a SwiftUI-facing
     color/font *facade* (only the per-value `.swiftUI` bridge exists so far).
3. **Phase 2 — Shared tracker interaction layer and tracker cutover.**
   - **Landed and cut over:**
     `RuntimeStore` / `NavigationStore` are now `@Observable` (the AppKit `observe()`
     path is kept so both worlds coexist). Added `TrackerRootView`
     (`SwiftUITracker.swift`): reads the store directly, reuses the Core
     `TrackerRenderer`, and styles itself from `AppPalette`/`AppFonts`/`Token` via the
     `.swiftUI` bridges. `AppDelegate` always hosts it; the old tracker renderer gate
     and AppKit `TrackerView` path are removed.
   - **Supported tracker scope:** render, selection, activation/open/continue,
     terminal focus, delete, inline recolor, jump-to-attention, focus handoff, spinner,
     elapsed duration, and snippet updates.
   - **Removed tracker commands:** relay, broadcast, and spawn are not SwiftUI parity
     work and have been removed from the native tracker command surface.
   - **Quest-area reevaluation:** attach-to-quest is also out of scope for tracker
     parity and typed prompt effects. Do not spend SwiftUI tracker migration time
     porting it; revisit it with the upcoming quest-area overhaul.
   - **Do not do next:** add prompt-based tracker commands back to
     `SwiftUITracker.swift` or make `TrackerRootView` a second god file.
4. **Phase 3 — Dock, New Session modal, and remaining SwiftUI panes.** Apply the same
   extraction rule to the dock board and new-session modal, then continue with the
   remaining chrome. *(Not started.)*
5. **Phase 4 — Shell/chrome + navigation/focus.** Port status chrome; decide how much key
   routing stays AppKit. *(Not started.)*
6. **Phase 5 — Transport unification + decode-visibility** (workstream E fold-ins).
   - **Done (pending macOS build):** added `UnixSocketIO.readLine` and routed
     `UnixSocketMutationClient` through it; removed `ServeProcess`'s duplicate
     `sockaddr_un` builder in favor of `UnixSocketIO.withAddress`. Added
     `RuntimeDecodingDiagnostics.skippedItemCount` (recorded by the lossy decoder,
     unit-tested) so dropped server items are now a programmatic signal, not just stderr.
   - **Not yet done:** the streaming `UnixSocketServeClient` keeps its own buffered read
     loop (it spans many lines, so it isn't a `readLine` caller); surfacing the decode
     skip count in the UI is a later increment.

Each phase is independently shippable and leaves the app working. Phases 0, 1, 2, and 5
have landed for the tracker path; Phase 3 is the next pane-migration direction.

## Decisions

- **Deployment target: macOS 14** (was macOS 13). Bumping is acceptable and has already
  landed in the foundation work. This unlocks the two APIs the migration leans on —
  `@Observable` (Observation framework) for the store layer, and `.onKeyPress` for
  native keyboard handling — so the focus model can be built without a fallback AppKit
  key-routing layer except where the terminal island requires it.
  - With `@Observable` available, the store layer in workstream A uses it directly; no
    Combine `ObservableObject`/`@Published` fallback needed.

## Open decisions

- **Exact home for tracker interaction code.** Default: pure decisions and state
  machines stay in `QuestmasterCore`; app-side glue that needs prompts, windows, or
  services lives in `Questmaster` as typed effects/executors. Do not put AppKit or
  SwiftUI imports in Core.
- **How much keyboard/focus routing stays AppKit.** Even with `.onKeyPress`, the
  `qm focus` edge handoff, global `NSEvent` monitors, and explicit first-responder
  control are precise in AppKit. Default assumption now: the shared interaction layer
  decides focus intent, while AppKit/SwiftUI shells apply focus mechanics only at their
  boundary. Revisit during Phase 4 with real code.

## Explicitly out of scope (for now)

- Rewriting the GhosttyKit terminal or the `ItemViewer` rich-text viewer in SwiftUI —
  they stay AppKit islands behind `NSViewRepresentable`.
- Any change to the Go `qm serve` backend or the wire protocol.
- The main-thread perf work (workstream E "keep separate") — tracked, not in this arc.

---

# Implementation guide for the deferred phases (worker handoff)

This section is written to be **self-contained**: a developer or coding agent should be
able to implement the remaining work from here without the originating chat. Everything
above is the rationale; everything below is the to-do.

## Ground rules / conventions

- **Branch:** use the current PR/worktree branch unless told otherwise. Commit messages:
  imperative subject, short body, no model identifiers in the message.
- **Build:** `swift build --package-path app` (full app bundle: `./app/Scripts/build-app.sh`).
  The package is macOS-only (AppKit + a GhosttyKit binary `xcframework` fetched from a GitHub
  release) — **it does not build on Linux**. Verify on macOS.
- **Tests:** `swift run --package-path app QuestmasterLogicTests`. This runs the pure-Core
  suites in-process **and** spawns `Questmaster --run-logic-tests` (the app's `LogicSelfTests`),
  asserting the output contains `Questmaster self-tests: N passed`. If you add app-side
  self-tests you must bump `N` in `app/Tests/QuestmasterLogicTests/main.swift`; pure-Core
  suites are added by appending a `XxxTests.run()` call in that same `main.swift` and do not
  affect `N`.
- **Where logic goes:** any decision/parsing/state-machine logic belongs in
  `QuestmasterCore` (no AppKit/SwiftUI imports) with a `XxxTests` in the harness.
  Side-effect glue that needs windows, prompts, mutation clients, or app services lives in
  `Questmaster` behind typed effects/executors. Views stay thin: they render shared state
  and dispatch commands, but do not own tracker-specific branching.
- **Stores & observation:** `RuntimeStore` / `NavigationStore` (in Core) are `@Observable`.
  SwiftUI views read them as a plain `let store: RuntimeStore` — reading a property inside
  `body` is enough to track it (no `@State`/`@Bindable` needed unless you need a binding).
  AppKit views still use the retained `store.observe { }` closure path; **both fire on every
  mutation**, so AppKit and SwiftUI panes coexist. Mutate state only through the store's
  methods (`apply`, `setServeConnectionState`, `setCurrentTerminalSessionID`).
- **Tracker path:** `AppDelegate` always hosts the SwiftUI tracker. Do not reintroduce
  renderer gates for the deleted AppKit tracker. New tracker behavior should stay in
  Core command/state types plus typed effects, with `SwiftUITracker.swift` acting as an
  event adapter and renderer.
- **Design tokens:** style every new view from `AppPalette` / `AppFonts` / `Token`
  (`app/Sources/App/SharedUI/DesignTokens.swift`). In SwiftUI use the `.swiftUI` bridges
  (`someNSColor.swiftUI` → `Color`, `someNSFont.swiftUI` → `Font`). Do not introduce raw
  hex or magic-number radii/spacing — add a `Token` if one is missing.

## Current-state file inventory

New (this migration):
- `app/Sources/Core/Stores/RuntimeStore.swift` — `@Observable` runtime state + `observe()`.
- `app/Sources/Core/Stores/NavigationStore.swift` — `@Observable` wrapper over `AppNavigationState`.
- `app/Sources/Core/Rendering/DisplayClassification.swift` — `AgentKind`/`SessionRoleKind`/`QuestStatusKind`.
- `app/Sources/App/SharedUI/DesignTokens.swift` — `Token.Radius`/`Token.Spacing` + `.swiftUI` bridges.
- `app/Sources/App/Tracker/SwiftUITracker.swift` — default tracker renderer/event adapter.
- `RuntimeDecodingDiagnostics` (in `RuntimeDecoding.swift`) — skipped-item counter.

The AppKit panes still in place: `DockView`+`QuestBoardListView`+`QuestBoardRenderer`
(dock board; still uses the shared `RepoSectionedListView` list infrastructure),
`ItemViewer`+`QuestViewerRenderer`+`QuestCommentComposerView` (quest viewer — viewer
stays an island), `NewSessionModal`+`NewSessionFieldViews`, and
`MainSplitView`+`ShellTopBars`+`ShellStatusViews`+`ShellControls` (shell/chrome).

## Phase 2 — Tracker Command/Interaction Layer

The SwiftUI tracker is the tracker path. Keep it narrow: render rows from
`TrackerRenderer`, translate input through `TrackerEventCommandResolver`, and dispatch
Core `TrackerCommand` effects through `TrackerEffectExecutor`.

1. **Keep supported tracker behavior centralized.** Selection movement/recovery,
   activation/open/continue, jump-to-attention, delete, inline recolor, focus handoff,
   terminal focus, and mutation construction should stay in `QuestmasterCore` command
   and state types where possible.
2. **Do not restore removed prompt commands.** Relay, broadcast, and spawn were removed
   from the native tracker surface instead of ported. Attach-to-quest remains pending
   the quest-area overhaul and should not be added back to tracker migration work.
3. **Keep AppKit list infrastructure scoped.** `RepoSectionedListView` is still shared
   by the quest board. Do not delete it as part of tracker cleanup unless the quest
   board has been migrated too.
4. **Acceptance for tracker edits:** keyboard parity for retained commands, recolor
   parity, spinner/elapsed parity, selection recovery after delete, and no prompt-based
   tracker command bodies in `SwiftUITracker.swift`.

## Phase 3 — Dock, New Session modal, and remaining SwiftUI panes

Apply the same extraction rule before each port: if an AppKit callback makes a domain
decision, move that decision to Core or the shared interaction layer before SwiftUI uses it.
The tracker already follows this pattern; apply it next to dock and new session.

### Dock (`DockRootView`, behind e.g. `QUESTMASTER_SWIFTUI_DOCK`)
- **Board list** → SwiftUI using `QuestBoardRenderer` + `BoardModels` (Core). Section tabs
  (active / …) map to `DockView.currentSection` / `BoardSection`. Selecting a quest sets the
  active quest (`RuntimeStore` already tracks `activeQuestID` via `RuntimeSnapshot`); the
  viewer reacts. Persist width with Core `DockWidthPreference`. Reference: `DockView.swift`,
  `QuestBoardListView.swift`, `QuestBoardRenderer.swift`.
- **Quest viewer** → keep `ItemViewer` (interactive `NSAttributedString`/`NSTextView`) as an
  **`NSViewRepresentable` island**; do not rewrite it in SwiftUI. Cursor/keyboard logic is
  already in Core (`QuestDetailCursor`, `QuestDetailRenderKey`). Comment composer logic is
  Core `QuestCommentComposerLogic`/`Model`. Quest mutations: `ServeMutationRequests.quest*`
  (gate toggle, comment add/edit/delete/resolve, status). Reference: `ItemViewer.swift`,
  `QuestViewerRenderer.swift`, `QuestCommentComposerView.swift`.

### New Session modal (`NewSessionRootView`)
- Port to a SwiftUI sheet/window backed by Core `NewSessionFormModel` (`NewSessionLogic.swift`)
  — already a complete state machine: focusable fields (`NewSessionField`), selection cycling,
  validation, and `submitPayload()`. The SwiftUI view is a thin renderer over it.
- Directory autocomplete: `ServeDirectorySuggesting.suggestDirectories(query:)` (the existing
  `UnixSocketMutationClient` conforms). Submit via `ServeMutationRequests.start`.
- Reference: `NewSessionModal.swift`, `NewSessionFieldViews.swift`,
  `AppDelegate.presentNewSession`.

## Phase 4 — Shell/chrome + focus/navigation

- **Shell.** `MainSplitView` does the 3-pane + side-card layout, animation, dock resize, and
  traffic-light positioning. Lowest-risk path: keep `MainSplitView` as an AppKit container
  that hosts the SwiftUI panes; port only the pills/status bars (`ShellTopBars`,
  `ShellStatusViews`) to SwiftUI reading `NavigationStore` + `ServeConnectionState`. Porting
  the split itself to SwiftUI is optional and higher-risk.
- **Focus/navigation.** `NavigationStore` is the source of truth (`focus`, `toggleTracker`,
  `toggleDock`, `directionalRegionFocus`, `terminalEdgeHandoff`, `nativeControl`). Within
  SwiftUI panes use `@FocusState` + `.focusable()` + `.onKeyPress`. The cross-process
  `qm focus` edge handoff arrives via `FocusHandoffServer` → `AppDelegate.handleFocusHandoff`
  → `navigation.terminalEdgeHandoff(...)`; that must move SwiftUI focus to the target pane.
  The `Cmd-[`/`Cmd-]` region monitor (`AppDelegate.installCommandKeyMonitor`) and the menu
  commands stay in AppKit. **Open decision** (resolve here with real code): how much key
  routing stays AppKit vs. native SwiftUI at the terminal-island boundary.
- **Decode visibility (finish Phase 5).** Surface `RuntimeDecodingDiagnostics.skippedItemCount`
  in a status/banner so backend drift is visible; reset after surfacing.
- **Cut over.** Remove any temporary renderer gates, delete the remaining AppKit pane views, and shrink
  `AppDelegate` to dependency composition and side-effect routing: focus application,
  mutation send, terminal switch, confirmations/status, app/window services, menus, signals,
  window/traffic-light setup, and the two AppKit islands (terminal + quest viewer). It should
  not own tracker-specific branching.

## Workstream A finish — `SessionCoordinator`

Move `sendMutation`, `switchTerminal`, `activateTerminalSession`, and the
`shouldClearTerminal`/`showTerminalSessionEnded` orchestration out of `AppDelegate` into a
`SessionCoordinator` over the `ServeMutationSending` protocol, holding a reference to
`RuntimeStore`. Phase 2 can emit typed effects that this coordinator executes. `AppDelegate`
may route effects temporarily, but it should not decide tracker-specific behavior.

## Remaining cleanups (anytime; low risk)

- Full inline-literal token sweep (remaining `cornerRadius`/inset literals not yet migrated).
- A SwiftUI-facing semantic color/font facade (only per-value `.swiftUI` bridges exist today).
- The "keep separate" smells: async `loadLoginShellEnvironment()`; async/off-main attributed
  string build in `ItemViewer`; clean up temp tmux startup dirs in `NSTemporaryDirectory()`;
  remove the dead all-`true` branch in `AppDelegate.validateMenuItem`.

## Gotchas discovered while building the foundation (read before editing)

- `SwiftUITracker.swift` is the default renderer, not the source of truth for tracker
  decisions. Keep adding behavior to Core command/state types first, then adapt events
  in the SwiftUI file.
- `@Observable` coexists with the manual `observe()` path because the observer dictionary is
  `@ObservationIgnored`. Don't remove `observe()` until **all** AppKit observers are gone.
- `NSHostingView` first-responder/focus is finicky; the current tracker uses a best-effort
  `makeFirstResponder`. Expect to revisit this in Phase 4's focus work.
- Verify the `Font(self as CTFont)` bridge in `DesignTokens.swift` compiles on your toolchain;
  if not, replace with an explicit `Font.system`/`Font.custom` mapping.
- None of the migration commits were compiled in the authoring environment (no Swift toolchain
  there) — **treat the first macOS build as the real compile check** and expect to fix small
  things.
