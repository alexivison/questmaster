# Ornament Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the app's flank artwork, frame the session pill with grand flanks, add a no-scroll tracker footer ornament, and simplify the artifact viewer header.

**Architecture:** `FlankedOrnamentRule` remains the one shared App-layer renderer and gains a two-case style enum backed by bundled SVG resources. A small pure-Core predicate decides whether the tracker footer can fit; the SwiftUI list measures the pre-footer content and viewport, then renders the footer only when that predicate allows it.

**Tech Stack:** Swift 5.9, SwiftUI, AppKit, Swift Package Manager, custom Core logic-test runner.

## Global Constraints

- macOS 14 target; use existing `AppPalette`, `AppFonts`, and `Token` styling.
- Keep Core Foundation-only; place the fit predicate under `Sources/Core/Tracker`.
- Do not add dependencies or UI unit-test targets; UI is verified by build and render preview.
- Preserve all current `FlankedOrnamentRule` callers except the artifact viewer header, which must no longer use it.
- The tracker footer must never create a scrollable list by appearing.

---

### Task 1: Prove the tracker-footer fit rule in Core

**Files:**
- Create: `app/Sources/Core/Tracker/TrackerEndOrnamentVisibility.swift`
- Create: `app/Tests/QuestmasterLogicTests/TrackerEndOrnamentVisibilityTests.swift`
- Modify: `app/Tests/QuestmasterLogicTests/main.swift`

**Interfaces:**
- Produces: `TrackerEndOrnamentVisibility.shows(contentHeight:viewportHeight:ornamentHeight:) -> Bool`.
- Consumes: `Double` measurements supplied by the App target; no AppKit or SwiftUI imports.

- [ ] **Step 1: Write the failing Core test**

```swift
struct TrackerEndOrnamentVisibilityTests {
    static func run() {
        expect(
            TrackerEndOrnamentVisibility.shows(contentHeight: 120, viewportHeight: 200, ornamentHeight: 44),
            "footer should show when content and ornament fit"
        )
        expect(
            TrackerEndOrnamentVisibility.shows(contentHeight: 156, viewportHeight: 200, ornamentHeight: 44),
            "footer should show at the exact fit boundary"
        )
        expect(
            !TrackerEndOrnamentVisibility.shows(contentHeight: 157, viewportHeight: 200, ornamentHeight: 44),
            "footer should hide when it would overflow"
        )
    }
}
```

Add `TrackerEndOrnamentVisibilityTests.run()` to `QuestmasterLogicTests.main()`.

- [ ] **Step 2: Run the logic test to verify it fails**

Run: `swift run --package-path app QuestmasterLogicTests`

Expected: compilation failure because `TrackerEndOrnamentVisibility` does not exist.

- [ ] **Step 3: Add the minimal predicate**

```swift
public enum TrackerEndOrnamentVisibility {
    public static func shows(contentHeight: Double, viewportHeight: Double, ornamentHeight: Double) -> Bool {
        contentHeight + ornamentHeight <= viewportHeight
    }
}
```

- [ ] **Step 4: Run the logic test to verify it passes**

Run: `swift run --package-path app QuestmasterLogicTests`

Expected: all suites pass, including `TrackerEndOrnamentVisibilityTests`.

- [ ] **Step 5: Commit the Core fit rule**

```bash
git add app/Sources/Core/Tracker/TrackerEndOrnamentVisibility.swift app/Tests/QuestmasterLogicTests/TrackerEndOrnamentVisibilityTests.swift app/Tests/QuestmasterLogicTests/main.swift
git commit -m "feat: gate tracker end ornament on available space"
```

### Task 2: Add the supplied SVGs and update the shared flank renderer

**Files:**
- Create: `app/Sources/App/Resources/Ornaments/side-ornament.svg`
- Create: `app/Sources/App/Resources/Ornaments/side-ornament-grand.svg`
- Create: `app/Sources/App/Resources/Ornaments/tracker-end-ornament.svg`
- Delete: `app/Sources/App/Resources/Ornaments/session_frame.svg`
- Modify: `app/Sources/App/SharedUI/FlankedOrnamentRule.swift`

**Interfaces:**
- Produces: `FlankedOrnamentRule.Style.default` and `.grand`; the initializer defaults to `.default`.
- Consumes: the existing `color` and `centerSpacing` inputs; callers remain source-compatible unless they select `.grand`.

- [ ] **Step 1: Copy the source artwork without editing it**

Copy the three approved files from `/Users/aleksi.tuominen/Downloads/ornaments/` into the App resource directory. Remove the now-unused `session_frame.svg`.

- [ ] **Step 2: Replace the hand-drawn shape with an SVG-backed style enum**

Define the two cases directly inside `FlankedOrnamentRule`. Map `.default` to `side-ornament.svg` at its 118×18 intrinsic canvas and `.grand` to `side-ornament-grand.svg` at 94×41. Load each with `AppSymbolStyle.resourceImage`, tint it with the existing rule color, mirror the right flank, and retain the SVG aspect ratio as the flanks compress in narrow layouts. Delete `SectionTitleOrnament` and the old rectangle-line composition because the assets include their own outward rule.

- [ ] **Step 3: Build the App target**

Run: `swift build --package-path app`

Expected: the package compiles and processes all three new ornament resources.

- [ ] **Step 4: Commit the shared ornament migration**

```bash
git add app/Sources/App/Resources/Ornaments app/Sources/App/SharedUI/FlankedOrnamentRule.swift
git commit -m "feat: use supplied flank ornaments"
```

### Task 3: Compose the session pill, tracker footer, and plain artifact header

**Files:**
- Modify: `app/Sources/App/SharedUI/SectionedList.swift`
- Modify: `app/Sources/App/Shell/ShellChromeControls.swift`
- Modify: `app/Sources/App/Shell/ShellTopBars.swift`
- Modify: `app/Sources/App/Tracker/SwiftUITracker.swift`
- Modify: `app/Sources/App/Tracker/TrackerListMetrics.swift`

**Interfaces:**
- Consumes: `FlankedOrnamentRule(style: .grand)`, `TrackerEndOrnamentVisibility.shows`, and `tracker-end-ornament.svg`.
- Produces: a session pill with grand flanks, an ornament-free artifact viewer title, and a tracker-only footer that is omitted before it can overflow.

- [ ] **Step 1: Refactor the session pill to use grand flanks**

Move the existing title/ID `VStack` inside `FlankedOrnamentRule(style: .grand)`. Keep the current hover fill and copy behavior; remove `frameImage`, `sessionFrame`, `ScrollCornerOrnaments`, and `ScrollCornerOrnament` because the old border is no longer rendered.

- [ ] **Step 2: Remove artifact viewer title flanks**

In `DockTopBar.viewerBar`, replace the `FlankedOrnamentRule` title wrapper with the existing `sideCardTopBarTitle(title)` constrained to the available width. Do not alter the back, copy, refresh, or close controls.

- [ ] **Step 3: Add a tracker-only measured footer slot to `SectionedList`**

Keep the existing scroll-to-selection behavior. Add an optional footer closure and required footer height that are used only by the tracker call site. Measure the scroll viewport and the list content before the footer with local SwiftUI preference keys. Render the footer only when `TrackerEndOrnamentVisibility.shows` receives the measured values and returns true; preserve the existing bottom padding in the tested required height so showing the footer cannot introduce overflow.

- [ ] **Step 4: Supply the tracker footer**

In `TrackerRootView`, pass a centered, noninteractive 156×44 image loaded from `tracker-end-ornament.svg`, along with its total vertical requirement. Only supply it when rows exist; empty and serve-starting states retain their current layouts.

- [ ] **Step 5: Build and render the updated App**

Run: `swift build --package-path app`

Run: `preview_dir=$(mktemp -d); swift run --package-path app Questmaster --render-preview "$preview_dir"; find "$preview_dir" -type f -maxdepth 1 -print`

Expected: build succeeds and the preview command writes tracker, terminal-top-bar, section-header, and artifact-viewer PNGs for visual inspection.

- [ ] **Step 6: Commit the composed UI change**

```bash
git add app/Sources/App/SharedUI/SectionedList.swift app/Sources/App/Shell/ShellChromeControls.swift app/Sources/App/Shell/ShellTopBars.swift app/Sources/App/Tracker/SwiftUITracker.swift app/Sources/App/Tracker/TrackerListMetrics.swift
git commit -m "feat: refresh session and tracker ornaments"
```

### Task 4: Run the final project checks and inspect scope

**Files:**
- Verify only; no planned source changes.

- [ ] **Step 1: Run the complete native-app checks**

Run: `swift build --package-path app`

Run: `swift run --package-path app QuestmasterLogicTests`

Expected: both commands exit successfully and the logic runner prints `Questmaster self-tests: ... passed`.

- [ ] **Step 2: Inspect the final diff**

Run: `git status --short && git diff main...HEAD --check && git diff --stat main...HEAD`

Expected: only the approved ornament assets, shared renderer, tracker/session/artifact UI, Core fit predicate, its test, and design/plan documents are changed.
