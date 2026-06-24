# Questmaster.app — Architecture Modernization Plan

Status: **Draft / not started.** This is a planning doc to capture the idea so we
don't lose it. Nothing here is committed work yet.

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
2. **Phase 1 — Token foundation.** Stand up the unified token layer (dual NS*/SwiftUI),
   migrate `AppPalette`/`ShellMetrics`/inline literals behind it. Move status/role/agent
   classification into Core.
3. **Phase 2 — Tracker in SwiftUI.** First real pane port via `NSHostingView`, consuming
   the store + tokens. Delete the corresponding `RepoSectionedListView` diffing code.
4. **Phase 3 — Dock + New Session modal** ported the same way.
5. **Phase 4 — Shell/chrome + navigation/focus.** Resolve the deployment-target decision;
   port status chrome; decide how much key routing stays AppKit.
6. **Phase 5 — Transport unification + decode-visibility** (workstream D fold-ins), once
   services are behind protocols.

Each phase is independently shippable and leaves the app working.

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
