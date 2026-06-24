# Questmaster.app — Architecture Modernization Plan

Status: **In progress — foundation landed (Phases 0, 1, 5); Phase 2 first proof landed
(SwiftUI Tracker behind a flag); Phases 3–4 not started** (all pending macOS build
verification; no Swift toolchain in the dev sandbox). This is a planning doc capturing the
overall idea.

## TL;DR

Three things we keep circling back to are actually **one coordinated refactor**:

1. **The missing view-model layer** — `AppDelegate` (~985 lines) is a god object
   because there is no observable model between the data clients and the views, so
   it has to manually push state into every view (`renderSnapshot()` →
   `setSnapshot()` → per-row signature diffing).
2. **A potential SwiftUI port** — the app is pure programmatic AppKit today.
3. **A design-token system** — colors/fonts/metrics are partly centralized
   (`AppPalette`, `AppFonts`, `ShellMetrics`) but radii/insets and a second metrics
   struct are scattered as inline literals, and the palette duplicates state
   classification that already lives in `QuestmasterCore`.

Doing any one alone gets ~half the value. The view-model layer is the keystone:
it makes the snapshot observable (which is what SwiftUI wants) and gives tokens a
clean place to be consumed. The plan is to land the **store/view-model layer first
under existing AppKit** (low risk, fully testable), then port to SwiftUI
pane-by-pane, folding the token cleanup in as views are rewritten.

## Why these are coupled

- `AppDelegate` is a god object *because* there's no observable model. Introducing
  view-models without SwiftUI still leaves us hand-writing push-rendering and the
  `signature` / `QuestDetailRenderKey` diffing. Adopting SwiftUI without view-models
  just recreates the god object as one giant `@Observable` blob. **Combined**, each
  fixes the other's leftover: the store gives structure, SwiftUI's `@Observable`
  gives observation + diffing for free, and that deletes most of `RepoSectionedListView`'s
  manual diffing machinery.
- Design tokens only pay off once views read from a shared semantic layer. A SwiftUI
  rewrite touches every view body anyway — that's the cheapest moment to swap inline
  literals for tokens, so the token work should *ride along* with each pane's port
  rather than be a separate sweep.

## What carries over for free

- **`QuestmasterCore` stays pure and unchanged.** Models, state machines
  (`NavigationLogic`, `NewSessionFormModel`, `TrackerRecolorState`), mutation builders,
  selection/cursor logic — all UI-agnostic value types. They become the spine of the
  view-model layer verbatim.
- **`RuntimeSnapshot.apply(_:)`** already *is* the merge logic. We delete the plumbing
  around it, not the logic itself.
- **The vendored `GhosttyTerminalRepresentable.swift`** already exists, so the terminal
  is SwiftUI-ready as an `NSViewRepresentable`.

## Target architecture

```
QuestmasterCore (pure: models, state machines, mutation builders)   ← unchanged
        ▲
Stores  (@Observable: RuntimeStore, NavigationStore, coordinators)  ← NEW
        ▲                       holds Core state machines, calls services
Views   (SwiftUI, reading stores declaratively — no setSnapshot, no signatures)
        ▲
AppKit islands (terminal, rich-text quest viewer) via NSViewRepresentable
```

`AppDelegate`'s current responsibilities decompose as:

| Today (in `AppDelegate`) | Becomes |
|---|---|
| `snapshot` + `apply(update)` + `renderSnapshot()` | **`RuntimeStore`** (`@Observable`, single source of truth) |
| `AppNavigationState` + focus/toggle methods | **`NavigationStore`** (wraps the existing pure state machine) |
| `sendMutation`, `switchTerminal`, `activateTerminalSession` | **`SessionCoordinator`** (orchestration over services) |
| `ServeProcess` / `ServeClient` / mutation client lifecycle | **services**, protocol-bound, injected into stores |
| menus, signal handlers, traffic-light geometry, terminal host | thin `NSApplicationDelegate` shell + AppKit islands |

Inbound path collapses from "client → `apply` → `renderSnapshot` → manual fan-out to
3 views" into roughly:

```swift
@Observable final class RuntimeStore {
    private(set) var snapshot: RuntimeSnapshot
    func handle(_ update: RuntimeUpdate) { snapshot.apply(update) }  // views re-diff automatically
}
```

## Workstreams

### A. View-model / store extraction (the keystone)
- Extract `RuntimeStore`, `NavigationStore`, and a `SessionCoordinator` out of `AppDelegate`.
- Define the data clients behind protocols already half-present (`RuntimeClient`,
  `ServeMutationSending`, `ServeDirectorySuggesting`) and inject them — enables tests
  and previews with fakes.
- **Can land entirely under existing AppKit** (views still get `setSnapshot()`, now from
  a store). This de-risks everything downstream and ships value even if SwiftUI stalls.

### B. SwiftUI port (pane by pane)
- Host SwiftUI inside the existing `NSWindow`/split via `NSHostingView`; migrate one
  region at a time behind the same `RuntimeStore`.
- Suggested order (most list-shaped / biggest diffing deletion first):
  1. **Tracker** (deletes the most `RepoSectionedListView` signature machinery)
  2. **Dock** quest board
  3. **New Session modal**
  4. Status chrome / top bars
- **Keep as AppKit islands:** the GhosttyKit terminal and the `ItemViewer` rich-text
  quest viewer (interactive `NSAttributedString` / `NSTextView`).
- **Deployment target: bumping to macOS 14** (decided — see below). This unlocks
  `@Observable` and `.onKeyPress`, so the focus model can be done natively without a
  fallback AppKit key-routing layer.

### C. Design tokens
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

### D. Other smells worth folding in (decide per-item; avoid scope creep)

**Fold in — they co-locate naturally with A/C:**
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
   - **Done (pending macOS build):** `RuntimeStore` + `NavigationStore` added to
     `QuestmasterCore` (pure, unit-tested in the logic harness via `RuntimeStoreTests` /
     `NavigationStoreTests`). `AppDelegate` now owns the snapshot, serve-connection state,
     terminal-session id, and navigation through the stores instead of bare properties.
     `TrackerView.bind(to:)` observes `RuntimeStore` and self-refreshes, so `renderSnapshot()`
     no longer pushes into the tracker. Behavior is intended to be unchanged.
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
3. **Phase 2 — Tracker in SwiftUI.** First real pane port via `NSHostingView`, consuming
   the store + tokens.
   - **Done (pending macOS build):** `RuntimeStore` / `NavigationStore` are now `@Observable`
     (the AppKit `observe()` path is kept so both worlds coexist). Added `TrackerRootView`
     (`SwiftUITracker.swift`): reads the store directly, reuses the Core `TrackerRenderer`,
     and styles itself from `AppPalette`/`AppFonts`/`Token` via the `.swiftUI` bridges.
     Wired into `AppDelegate` behind the `QUESTMASTER_SWIFTUI_TRACKER` flag (or
     `--swiftui-tracker`); the AppKit `TrackerView` stays the default, so this is an
     additive, verifiable proof rather than a destructive swap.
   - **Scope of this first proof:** render + selection + activation (activation reuses the
     Core `TrackerActivationDecision` + existing switch/continue plumbing).
   - **Not yet done:** keyboard command navigation, inline recolor editing, and animated
     spinners are not ported; the AppKit `RepoSectionedListView` diffing code is **not**
     deleted yet — that happens only once the SwiftUI pane is build-verified and reaches
     interaction parity.
4. **Phase 3 — Dock + New Session modal** ported the same way. *(Not started.)*
5. **Phase 4 — Shell/chrome + navigation/focus.** Port status chrome; decide how much key
   routing stays AppKit. *(Not started.)*
6. **Phase 5 — Transport unification + decode-visibility** (workstream D fold-ins).
   - **Done (pending macOS build):** added `UnixSocketIO.readLine` and routed
     `UnixSocketMutationClient` through it; removed `ServeProcess`'s duplicate
     `sockaddr_un` builder in favor of `UnixSocketIO.withAddress`. Added
     `RuntimeDecodingDiagnostics.skippedItemCount` (recorded by the lossy decoder,
     unit-tested) so dropped server items are now a programmatic signal, not just stderr.
   - **Not yet done:** the streaming `UnixSocketServeClient` keeps its own buffered read
     loop (it spans many lines, so it isn't a `readLine` caller); surfacing the decode
     skip count in the UI is a later increment.

Each phase is independently shippable and leaves the app working. Phases 0, 1, and 5 (the
foundation) are implemented; the SwiftUI pane ports (2–4) are intentionally not started.

## Decisions

- **Deployment target: macOS 14** (was macOS 13). Bumping is acceptable. This unlocks
  the two APIs the migration leans on — `@Observable` (Observation framework) for the
  store layer, and `.onKeyPress` for native keyboard handling — so the focus model can
  be built in SwiftUI without a fallback AppKit key-routing layer. Update the
  `.macOS(.v13)` line in `Package.swift` when Phase 1 begins (no benefit bumping it
  before SwiftUI code lands).
  - With `@Observable` available, the store layer in workstream A uses it directly; no
    Combine `ObservableObject`/`@Published` fallback needed.

## Open decisions

- **How much keyboard/focus routing stays AppKit.** Even with `.onKeyPress`, the
  `qm focus` edge handoff, global `NSEvent` monitors, and explicit first-responder
  control are precise in AppKit. Default assumption now: do focus natively in SwiftUI
  and only keep AppKit routing where it proves necessary at the terminal-island
  boundary. Revisit during Phase 4 with real code.

## Explicitly out of scope (for now)

- Rewriting the GhosttyKit terminal or the `ItemViewer` rich-text viewer in SwiftUI —
  they stay AppKit islands behind `NSViewRepresentable`.
- Any change to the Go `qm serve` backend or the wire protocol.
- The main-thread perf work (workstream D "keep separate") — tracked, not in this arc.

---

# Implementation guide for the deferred phases (worker handoff)

This section is written to be **self-contained**: a developer or coding agent should be
able to implement the remaining work from here without the originating chat. Everything
above is the rationale; everything below is the to-do.

## Ground rules / conventions

- **Branch:** `claude/swift-app-architecture-ua6jnw` (base: `origin/main`). Keep committing
  here unless told otherwise. Commit messages: imperative subject, short body, no model
  identifiers in the message.
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
  `QuestmasterCore` (no AppKit/SwiftUI imports) with a `XxxTests` in the harness. Views stay
  thin. This is why the panes can be re-skinned cheaply — the logic is already extracted.
- **Stores & observation:** `RuntimeStore` / `NavigationStore` (in Core) are `@Observable`.
  SwiftUI views read them as a plain `let store: RuntimeStore` — reading a property inside
  `body` is enough to track it (no `@State`/`@Bindable` needed unless you need a binding).
  AppKit views still use the retained `store.observe { }` closure path; **both fire on every
  mutation**, so AppKit and SwiftUI panes coexist. Mutate state only through the store's
  methods (`apply`, `setServeConnectionState`, `setCurrentTerminalSessionID`).
- **Per-pane flag pattern:** the SwiftUI Tracker is gated by `QUESTMASTER_SWIFTUI_TRACKER=1`
  (or `--swiftui-tracker`), parsed in `AppConfig.load()` and branched in
  `AppDelegate.createWindow()`. Follow the same pattern for each new pane: add a flag, build
  the SwiftUI view in an `NSHostingView`, keep the AppKit view as the default until parity is
  verified, then flip the default and delete the AppKit view in a separate commit.
- **Design tokens:** style every new view from `AppPalette` / `AppFonts` / `Token`
  (`app/Sources/Questmaster/DesignTokens.swift`). In SwiftUI use the `.swiftUI` bridges
  (`someNSColor.swiftUI` → `Color`, `someNSFont.swiftUI` → `Font`). Do not introduce raw
  hex or magic-number radii/spacing — add a `Token` if one is missing.

## Current-state file inventory

New (this migration):
- `app/Sources/QuestmasterCore/RuntimeStore.swift` — `@Observable` runtime state + `observe()`.
- `app/Sources/QuestmasterCore/NavigationStore.swift` — `@Observable` wrapper over `AppNavigationState`.
- `app/Sources/QuestmasterCore/DisplayClassification.swift` — `AgentKind`/`SessionRoleKind`/`QuestStatusKind`.
- `app/Sources/Questmaster/DesignTokens.swift` — `Token.Radius`/`Token.Spacing` + `.swiftUI` bridges.
- `app/Sources/Questmaster/SwiftUITracker.swift` — `TrackerRootView` (Phase 2 proof).
- `RuntimeDecodingDiagnostics` (in `RuntimeDecoding.swift`) — skipped-item counter.

The AppKit panes still in place (to be ported then deleted): `TrackerView`+`RepoSectionedListView`
+`TrackerRowViews`+`RepoSectionedRowViews` (tracker), `DockView`+`QuestBoardListView`+
`QuestBoardRenderer` (dock board), `ItemViewer`+`QuestViewerRenderer`+`QuestCommentComposerView`
(quest viewer — viewer stays an island), `NewSessionModal`+`NewSessionFieldViews`,
`MainSplitView`+`ShellTopBars`+`ShellStatusViews`+`ShellControls` (shell/chrome).

## Phase 2 (finish) — Tracker parity, then delete the AppKit tracker

The SwiftUI proof (`TrackerRootView`) does render + selection + activation only. To reach
parity with `TrackerView`/`RepoSectionedListView` and remove them:

1. **Selection ownership.** Move selection out of `TrackerRootView`'s local `@State` so
   keyboard navigation can drive it (a small `@Observable TrackerSelectionStore`, or fold a
   `selectedSessionID` into `RuntimeStore`). Reuse Core `RepoListSelection`
   (`validSelectionID` / `nextSelectionID`, with wrap) — see `TrackerLogic.swift`.
2. **Keyboard.** Add `.onKeyPress` (macOS 14) handling: `hjkl` movement + the command set the
   AppKit list exposes via `listView.onCommand` — `.jumpToNextAttention`, `.relay`,
   `.broadcast`, `.delete`, `.attachToQuest`, `.spawn`, `.recolorSession`, `.recolorRepo`,
   `.previousTab`/`.nextTab`. Bindings live in `Keymap.List` (Core, `Keymap.swift`); the
   action bodies are in `TrackerViews.swift` (`relaySelected`, `broadcastSelected`,
   `deleteSelected`, `attachSelectedToQuest`, `spawnFromSelected`, `beginRecolorSelected`,
   `jumpToNextUnread`) — reuse the same Core mutation builders they call.
3. **Inline recolor.** Drive the existing state machine `TrackerRecolorState` /
   `TrackerRecolorPickerState` (Core, `TrackerLogic.swift`). Render the live preview by
   passing it to `TrackerRenderer.tracker(snapshot, recolorPreview:)`. Commit via
   `ServeMutationRequests.recolorSession` / `.recolorRepo`. Reference AppKit flow:
   `TrackerViews.beginRecolorSelected` + `handleInlineRecolorKey`.
4. **Spinners + duration.** A working session is `rendered.status.usesSpinner` (kind ==
   `.working`). Animate with `TimelineView(.animation)` (or a `Timer`-backed frame counter);
   render the elapsed label from `TrackerRenderer.durationLabel(for:now:)`.
5. **Prompts/confirms.** Relay/broadcast/spawn need text input; delete needs confirmation.
   Either reuse `MutationPrompts` (AppKit `NSAlert`, callable with the host window) or build
   SwiftUI sheets. Confirmation copy is in Core `DestructiveConfirmation`.
6. **Cut over.** Once parity is verified on a real build, flip `useSwiftUITracker` to default
   true, then in a **separate commit** delete `TrackerView`, `RepoSectionedListView`,
   `TrackerRowViews`, `RepoSectionedRowViews`, the tracker portion of `SkeletonViews`, and the
   flag branch. Acceptance: keyboard parity, recolor parity, spinner/elapsed parity, selection
   recovery after delete (Core `TrackerSelection`).

## Phase 3 — Dock + New Session modal

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
  `UnixSocketMutationClient` conforms). Submit via `ServeMutationRequests.start` / `.spawn`.
- Reference: `NewSessionModal.swift`, `NewSessionFieldViews.swift`,
  `AppDelegate.presentNewSession`.

## Phase 4 — Shell/chrome + focus/navigation, then remove the flags

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
- **Cut over.** Remove the per-pane flags, delete the remaining AppKit pane views, and shrink
  `AppDelegate` to: an `NSApplicationDelegate` shell (menus, signals, window, traffic lights),
  the stores, the services, and the two AppKit islands (terminal + quest viewer).

## Workstream A finish — `SessionCoordinator`

Move `sendMutation`, `switchTerminal`, `activateTerminalSession`, and the
`shouldClearTerminal`/`showTerminalSessionEnded` orchestration out of `AppDelegate` into a
`SessionCoordinator` over the `ServeMutationSending` protocol, holding a reference to
`RuntimeStore`. This is the last big chunk of `AppDelegate` state/logic; do it once the panes
no longer call back into `AppDelegate` directly.

## Remaining cleanups (anytime; low risk)

- Full inline-literal token sweep (remaining `cornerRadius`/inset literals not yet migrated).
- A SwiftUI-facing semantic color/font facade (only per-value `.swiftUI` bridges exist today).
- The "keep separate" smells: async `loadLoginShellEnvironment()`; async/off-main attributed
  string build in `ItemViewer`; clean up temp tmux startup dirs in `NSTemporaryDirectory()`;
  remove the dead all-`true` branch in `AppDelegate.validateMenuItem`.

## Gotchas discovered while building the foundation (read before editing)

- The AppKit `TrackerView` **re-renders itself internally** from its own stored snapshot on
  every edit (selection, recolor); it does **not** depend on `renderSnapshot()` pushing into
  it. `currentTerminalSessionID` is read only at *action* time, not during render. Preserve
  these properties if you touch the AppKit tracker.
- `@Observable` coexists with the manual `observe()` path because the observer dictionary is
  `@ObservationIgnored`. Don't remove `observe()` until **all** AppKit observers are gone.
- `NSHostingView` first-responder/focus is finicky; the current tracker uses a best-effort
  `makeFirstResponder`. Expect to revisit this in Phase 4's focus work.
- Verify the `Font(self as CTFont)` bridge in `DesignTokens.swift` compiles on your toolchain;
  if not, replace with an explicit `Font.system`/`Font.custom` mapping.
- None of the migration commits were compiled in the authoring environment (no Swift toolchain
  there) — **treat the first macOS build as the real compile check** and expect to fix small
  things.
