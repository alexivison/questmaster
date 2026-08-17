# Ornament polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refine the shared flank ornaments, session-pill hover state, and modal action decoration to match the approved visual direction.

**Architecture:** Keep all three flank appearances in `FlankedOrnamentRule.Style`. The simple rule is a native `LinearGradient`, while the two existing SVG variants retain their resource-loading path. Keep visual adjustments in their existing consumers so unrelated uses of the default rule do not move.

**Tech Stack:** Swift 5, SwiftUI, AppKit, Swift Package Manager.

## Global Constraints

- Keep the app target’s UI decisions in `app/Sources/App`; do not add a dependency or a Core type.
- Preserve the existing session-copy behavior, modal button actions, keyboard shortcut, footer hint, and layout insets.
- Do not add UI unit tests; this repository verifies App-target visuals through the debug render previews, Swift build, and the existing logic runner.
- Build with `swift build --package-path app` and run `swift run --package-path app QuestmasterLogicTests`.

---

### Task 1: Add the simple shared flank style and resize the grand style

**Files:**
- Modify: `app/Sources/App/SharedUI/FlankedOrnamentRule.swift:4-62`

**Interfaces:**
- Consumes: `FlankedOrnamentRule.Style`, `Color`, and `AppSymbolStyle.resourceImage`.
- Produces: `FlankedOrnamentRule.Style.simple`, which supports the existing `style`, `color`, and `centerSpacing` initializer arguments.

- [ ] **Step 1: Add the new style case and define its native-line geometry**

```swift
enum Style {
    case `default`
    case grand
    case simple

    var resourceName: String? {
        switch self {
        case .default: "side-ornament"
        case .grand: "side-ornament-grand"
        case .simple: nil
        }
    }

    var size: CGSize {
        switch self {
        case .default: CGSize(width: 118, height: 18)
        case .grand: CGSize(width: 85, height: 37)
        case .simple: CGSize(width: 0, height: 1)
        }
    }

    var minimumWidth: CGFloat {
        switch self {
        case .default: 40
        case .grand: 47
        case .simple: 24
        }
    }
}
```

- [ ] **Step 2: Render `.simple` as a mirrorable native gradient and retain the current stretched image path for the SVG styles**

```swift
if style == .simple {
    Rectangle()
        .fill(LinearGradient(
            colors: flippedHorizontally ? [color, color.opacity(0)] : [color.opacity(0), color],
            startPoint: .leading,
            endPoint: .trailing
        ))
        .frame(minWidth: style.minimumWidth, maxWidth: .infinity, minHeight: style.size.height, maxHeight: style.size.height)
        .layoutPriority(-1)
} else if let resourceName = style.resourceName, let image = AppSymbolStyle.resourceImage(
    name: resourceName,
    fileExtension: "svg",
    subdirectory: "Ornaments",
    canvasSize: style.size,
    tintColor: NSColor(color)
) {
    Image(nsImage: image)
        .resizable(capInsets: style.capInsets, resizingMode: .stretch)
        .frame(minWidth: style.minimumWidth, maxWidth: style.size.width, minHeight: style.size.height, maxHeight: style.size.height)
        .scaleEffect(x: flippedHorizontally ? -1 : 1, y: 1)
        .layoutPriority(-1)
}
```

- [ ] **Step 3: Build the App target**

Run: `swift build --package-path app`

Expected: the package compiles with the new enum case and its native gradient branch.

- [ ] **Step 4: Commit the shared rule**

```bash
git add app/Sources/App/SharedUI/FlankedOrnamentRule.swift
git commit -m "feat: add simple flank rule"
```

### Task 2: Align section text and refine session-pill hover behavior

**Files:**
- Modify: `app/Sources/App/SharedUI/SectionedList.swift:131-153`
- Modify: `app/Sources/App/Shell/ShellChromeControls.swift:339-400`
- Inspect: `app/Sources/App/Runtime/RenderPreview.swift:19-32,297-306`

**Interfaces:**
- Consumes: `FlankedOrnamentRule(style:color:centerSpacing:center:)` from Task 1.
- Produces: an optically aligned section title and a copyable session pill whose hover tints only its title and flanks.

- [ ] **Step 1: Offset only the section-header title by three points**

```swift
Text(title)
    .font(AppFonts.sectionTitle.swiftUI)
    .foregroundStyle(color.swiftUI)
    .lineLimit(1)
    .truncationMode(.tail)
    .layoutPriority(1)
    .offset(y: -3)
```

- [ ] **Step 2: Derive the pill’s ornament and title colors from its copyable hover state, and remove its background fill**

```swift
private var isHighlighted: Bool { isHovered && isCopyable }

private var ornamentColor: NSColor {
    isHighlighted ? AppPalette.brassActive : AppPalette.line
}

private var titleColor: NSColor {
    isHighlighted ? AppPalette.brassActive : AppPalette.activeText
}

FlankedOrnamentRule(style: .grand, color: ornamentColor.swiftUI, centerSpacing: 6) {
    VStack(spacing: 2) {
        Text(chip?.title ?? "Terminal")
            .font(AppFonts.bodyBold.withSize(ChromeMetrics.sessionChipTitlePointSize).serif.swiftUI)
            .tracking(ChromeMetrics.sessionChipTitleTracking)
            .foregroundStyle(titleColor.swiftUI)
            .lineLimit(1)
        if let id = chip?.id, !id.isEmpty {
            Text(id)
                .font(AppFonts.monoSmall.withSize(ChromeMetrics.sessionChipIDPointSize).swiftUI)
                .foregroundStyle(AppPalette.dim.swiftUI)
                .opacity(ChromeMetrics.sessionChipIDOpacity)
                .lineLimit(1)
        }
    }
}
```

Remove the existing `RoundedRectangle` hover background modifier entirely.

- [ ] **Step 3: Generate and inspect the affected render previews**

Run:

```bash
preview_dir=$(mktemp -d)
swift run --package-path app Questmaster --render-preview "$preview_dir"
open "$preview_dir/section-header.png"
open "$preview_dir/terminal-top-bar.png"
```

Expected: section-header text ends at the default ornament’s lower rule edge; terminal top-bar grand ornaments are visibly smaller and neutral at rest. Verify the hover tint in the installed app because static previews do not synthesize hover.

- [ ] **Step 4: Commit the alignment and hover changes**

```bash
git add app/Sources/App/SharedUI/SectionedList.swift app/Sources/App/Shell/ShellChromeControls.swift
git commit -m "style: refine ornament alignment and hover"
```

### Task 3: Use the simple flank rule in modal action footers and verify the app

**Files:**
- Modify: `app/Sources/App/SharedUI/ModalSheetScaffold.swift:50-75`
- Inspect: `app/Sources/App/Runtime/RenderPreview.swift:19-22,297-301`

**Interfaces:**
- Consumes: `FlankedOrnamentRule.Style.simple` from Task 1.
- Produces: modal action buttons flanked by fading hairlines instead of decorative SVGs.

- [ ] **Step 1: Wrap the existing action button row in the simple flank rule**

```swift
FlankedOrnamentRule(style: .simple, centerSpacing: Token.Spacing.element) {
    HStack(spacing: Token.Spacing.element) {
        if let cancelLabel, let onCancel {
            Button(cancelLabel, action: onCancel)
                .buttonStyle(OutlineButtonStyle())
        }
        if let primaryLabel, let onPrimary {
            if destructivePrimary {
                Button(primaryLabel, action: onPrimary)
                    .buttonStyle(DangerButtonStyle())
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(primaryLabel, action: onPrimary)
                    .buttonStyle(GoldButtonStyle())
            }
        }
    }
}
.padding(.horizontal, ModalSheetMetrics.footerRuleInset)
```

- [ ] **Step 2: Render the confirmation sheet and inspect its footer**

Run:

```bash
preview_dir=$(mktemp -d)
swift run --package-path app Questmaster --render-preview "$preview_dir"
open "$preview_dir/confirmation.png"
```

Expected: the action buttons retain their current order and styles, with a one-point gray line fading toward each outer edge.

- [ ] **Step 3: Run the project verification commands**

Run:

```bash
swift build --package-path app
swift run --package-path app QuestmasterLogicTests
./app/Scripts/build-app.sh
codesign --verify --deep --strict /Applications/Questmaster.app
```

Expected: both Swift commands and the app-bundle build succeed; the installed bundle verifies successfully.

- [ ] **Step 4: Commit the modal footer change**

```bash
git add app/Sources/App/SharedUI/ModalSheetScaffold.swift
git commit -m "style: use simple modal action flanks"
```
