# Sprig ornament style Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a reusable sprig flank style and use it beneath the artifact scope tabs.

**Architecture:** Extend the existing shared `FlankedOrnamentRule.Style` enum with one SVG-backed style. Its 30-point trailing cap preserves the full 29-point botanical region while the line to its outer edge stretches. `SegmentedPicker` opts into the style; no model or interaction code changes.

**Tech Stack:** Swift 5, SwiftUI, AppKit, Swift Package Manager.

## Global Constraints

- Keep this visual change in `app/Sources/App`; do not add dependencies or Core types.
- Copy the supplied SVG unchanged and preserve its SHA-256 checksum after import.
- Preserve selected/unselected tab colors, artifact scope behavior, accessibility, and the current 11-point ornament layout height.
- Do not add UI unit tests; verify this App-target visual change through the debug render preview, Swift build, and existing logic runner.

---

### Task 1: Add the shared sprig flank style

**Files:**
- Create: `app/Sources/App/Resources/Ornaments/side-ornament-2.svg`
- Modify: `app/Sources/App/SharedUI/FlankedOrnamentRule.swift:5-35`

**Interfaces:**
- Consumes: the imported `side-ornament-2.svg` resource.
- Produces: `FlankedOrnamentRule.Style.sprig`, usable through the existing `style`, `color`, and `centerSpacing` arguments.

- [ ] **Step 1: Add the supplied SVG’s exact source content and verify its checksum**

Run:

```bash
shasum -a 256 app/Sources/App/Resources/Ornaments/side-ornament-2.svg
```

Apply the source file’s exact content to `app/Sources/App/Resources/Ornaments/side-ornament-2.svg`. Expected checksum: `22b046f7e1d723973ee2e986898dc7e91a17f88821c6aa297891d59fc1289aba`.

- [ ] **Step 2: Define the sprig resource, geometry, and full fixed-art cap**

```swift
enum Style {
    case `default`
    case grand
    case simple
    case sprig

    var resourceName: String? {
        switch self {
        case .default: "side-ornament"
        case .grand: "side-ornament-grand"
        case .simple: nil
        case .sprig: "side-ornament-2"
        }
    }

    var size: CGSize {
        switch self {
        case .default: CGSize(width: 118, height: 18)
        case .grand: CGSize(width: 85, height: 37)
        case .simple: CGSize(width: 0, height: 1)
        case .sprig: CGSize(width: 111, height: 23)
        }
    }

    var minimumWidth: CGFloat {
        switch self {
        case .default: 48
        case .grand: 52
        case .simple: 24
        case .sprig: 30
        }
    }
}
```

The existing SVG branch already uses `minimumWidth` as its trailing cap inset, so the full sprig at x=81…111 stays fixed and only x=0…81 stretches.

```swift
case .default, .grand, .sprig:
    if let resourceName = style.resourceName, let image = AppSymbolStyle.resourceImage(
        name: resourceName,
        fileExtension: "svg",
        subdirectory: "Ornaments",
        canvasSize: style.size,
        tintColor: NSColor(color)
    ) {
        Image(nsImage: image)
            .resizable(capInsets: style.capInsets, resizingMode: .stretch)
            .frame(minWidth: style.minimumWidth, maxWidth: .infinity, minHeight: style.size.height, maxHeight: style.size.height)
            .scaleEffect(x: flippedHorizontally ? -1 : 1, y: 1)
            .layoutPriority(-1)
    }
```

- [ ] **Step 3: Build the App target**

Run: `swift build --package-path app`

Expected: the package compiles with `.sprig` and includes the imported resource.

- [ ] **Step 4: Commit the shared style**

```bash
git add app/Sources/App/Resources/Ornaments/side-ornament-2.svg app/Sources/App/SharedUI/FlankedOrnamentRule.swift
git commit -m "feat: add sprig ornament style"
```

### Task 2: Apply sprig ornaments to artifact scope tabs

**Files:**
- Modify: `app/Sources/App/SharedUI/SegmentedPicker.swift:25-32`
- Modify: `app/Sources/App/Dock/Artifact/ArtifactDockView.swift:186-199`
- Modify: `app/Sources/App/Tracker/SwiftUITracker.swift:415-420`
- Inspect: `app/Sources/App/Runtime/RenderPreview.swift:19-31,36-104,112-153`

**Interfaces:**
- Consumes: `FlankedOrnamentRule.Style.sprig` from Task 1.
- Produces: selected and unselected artifact scope tab rules drawn with the sprig asset.

- [ ] **Step 1: Set the picker’s existing flank rule to the new style**

```swift
FlankedOrnamentRule(
    style: .sprig,
    color: (option == selection ? AppPalette.brassActive : AppPalette.line).swiftUI,
    centerSpacing: 0
) {
    Color.clear.frame(width: 0, height: 0)
}
.frame(height: 11)
```

- [ ] **Step 2: Match the tracker header’s upper inset to its lower inset**

```swift
SectionHeader(
    title: repo.repo.name.isEmpty ? "ungrouped" : repo.repo.name,
    color: repo.color,
    topInset: 8,
    bottomInset: 8
)
```

- [ ] **Step 3: Increase the artifact tab’s two vertical gaps without changing horizontal centering**

```swift
VStack(spacing: Token.Spacing.element) {
    Text(title(option))
        .font(AppFonts.dockTabTitle.swiftUI)
        .textCase(.uppercase)
        .tracking(1.6)
        .foregroundStyle((option == selection ? AppPalette.accent : AppPalette.dim).swiftUI)
        .lineLimit(1)
    FlankedOrnamentRule(
        style: .sprig,
        color: (option == selection ? AppPalette.brassActive : AppPalette.line).swiftUI,
        centerSpacing: 0
    ) {
        Color.clear.frame(width: 0, height: 0)
    }
    .frame(height: 11)
}

.padding(.bottom, Token.Spacing.element)
```

Keep `centerSpacing: 0` and do not add an x-offset. The zero-width center plus equal flexible flanks remains the centered layout for each tab.

- [ ] **Step 4: Generate and inspect the artifact and tracker previews**

Run:

```bash
preview_dir=$(mktemp -d)
swift run --package-path app Questmaster --render-preview "$preview_dir"
open "$preview_dir/artifact-filter.png"
open "$preview_dir/artifact-select-list.png"
open "$preview_dir/tracker.png"
```

Expected: the selected and unselected scope tabs retain their current labels and colors, with undistorted, centered sprig flourishes at the inner tab edges and line-only extension to their outer edges. The title-to-ornament and ornament-to-search gaps each use ten-point layout spacing. Each tracker section header has equal visible space above and below its separator.

- [ ] **Step 5: Run the App build and logic suite**

Run:

```bash
swift build --package-path app
swift run --package-path app QuestmasterLogicTests
```

Expected: the App target builds and the logic runner reports all suites passed.

- [ ] **Step 6: Build and verify the installed bundle**

Run:

```bash
./app/Scripts/build-app.sh
codesign --verify --deep --strict /Applications/Questmaster.app
```

Expected: the production bundle installs to `/Applications/Questmaster.app` and signature verification succeeds.

- [ ] **Step 7: Commit the visual consumer changes**

```bash
git add app/Sources/App/SharedUI/SegmentedPicker.swift app/Sources/App/Dock/Artifact/ArtifactDockView.swift app/Sources/App/Tracker/SwiftUITracker.swift
git commit -m "style: refine sprig tabs and tracker spacing"
```
