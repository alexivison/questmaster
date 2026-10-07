import AppKit
import QuestmasterCore
import SwiftUI

/// The RPG-style action bar footer: a full-width strip at the bottom of the window replacing the
/// old `TerminalTopBar`. Per the first review round, the session panel and slot bar are two
/// separate, overlapping plates traced directly from the design's own SVGs
/// (`ActionBarPlateOutlines`), not a single shape built from `TrackerPlatePaths`. See
/// `ActionBarMetrics` for the rest of the geometry and the off-palette colour mapping, and
/// `app/Sources/Core/ActionBar` for the pure worker-strip/truncation/keymap logic this view reads.

private func tooltip(_ label: String, _ binding: Keymap.CommandBinding) -> String {
    "\(label)  \(binding.displayGlyph)"
}

@Observable
final class ActionBarFooterModel {
    var navigation: AppNavigationState
    var sessionChip: SelectedSessionChip?
    var sessionRole: SessionRoleKind?
    var workers: [TrackerSession]
    var highlightedWorkerID: String?
    var caffeineActive: Bool
    var dockContentMode: DockContentMode
    var workerStripState: ActionBarWorkerStripState

    init(
        navigation: AppNavigationState = AppNavigationState(),
        sessionChip: SelectedSessionChip? = nil,
        sessionRole: SessionRoleKind? = nil,
        workers: [TrackerSession] = [],
        highlightedWorkerID: String? = nil,
        caffeineActive: Bool = false,
        dockContentMode: DockContentMode = .artifacts,
        workerStripState: ActionBarWorkerStripState = ActionBarWorkerStripState()
    ) {
        self.navigation = navigation
        self.sessionChip = sessionChip
        self.sessionRole = sessionRole
        self.workers = workers
        self.highlightedWorkerID = highlightedWorkerID
        self.caffeineActive = caffeineActive
        self.dockContentMode = dockContentMode
        self.workerStripState = workerStripState
    }
}

struct ActionBarFooterView: View {
    let model: ActionBarFooterModel
    let onNewSession: () -> Void
    let onShowTracker: () -> Void
    let onHideTracker: () -> Void
    let onOpenArtifacts: () -> Void
    let onOpenQuests: () -> Void
    let onToggleCaffeine: () -> Void
    let onOpenSettings: () -> Void
    let onCopySessionID: (String) -> Void
    let onAttachWorker: (String) -> Void

    var body: some View {
        let navState = model.navigation
        ZStack(alignment: .topLeading) {
            // Stacking order, bottom to top: slot bar, session panel (overlapping its left end),
            // the title/ID strips (which start behind the portrait), then the portrait itself —
            // its ring and logo must stay fully visible over the strips, per the design.
            ActionBarPlateShapeView(path: ActionBarPlateOutlines.slotBar, fill: ActionBarMetrics.PlateFill.slotBar)
            ActionBarPlateShapeView(path: panelPath, fill: ActionBarMetrics.PlateFill.sessionPanel)
            strips
            portrait
            slotBar(navState: navState)
            ActionBarWorkerStripView(
                workers: model.workers,
                highlightedWorkerID: model.highlightedWorkerID,
                state: model.workerStripState,
                onAttach: onAttachWorker,
                onScroll: { side in
                    model.workerStripState.scroll(
                        toward: side,
                        workerCount: model.workers.count,
                        visibleCount: ActionBarWorkerStripCapacity.singleOverflow
                    )
                }
            )
            .offset(x: ActionBarMetrics.workerRowStartX, y: ActionBarMetrics.workerRowY)
        }
        .frame(width: ActionBarMetrics.plateWidth, height: ActionBarMetrics.footerHeight, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .center)
        .frame(height: ActionBarMetrics.footerHeight)
        // No background: the window behind the footer is already `AppPalette.window`, so only
        // the plate/pill shapes above should paint anything — exactly what should cover the dock
        // (now the window's full height) where the two happen to overlap, and nothing else.
    }

    private var panelVariant: ActionBarSessionPanelVariant {
        ActionBarSessionPanelVariant(role: model.sessionRole)
    }

    private var panelPath: Path {
        switch panelVariant {
        case .master: ActionBarPlateOutlines.masterPanel
        case .standalone: ActionBarPlateOutlines.standalonePanel
        case .worker: ActionBarPlateOutlines.workerPanel
        }
    }

    private var portrait: some View {
        ZStack {
            Circle().fill(AppPalette.panel.swiftUI)
            if let image = TrackerAgentMark.image(
                for: model.sessionChip?.agent ?? "",
                side: ActionBarMetrics.portraitSide * 0.615,
                tint: ActionBarMetrics.SourceColor.logo
            ) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: ActionBarMetrics.portraitSide * 0.615, height: ActionBarMetrics.portraitSide * 0.615)
                    .clipShape(Circle())
            }
            // A plain ring, no status colour — the user's call for the session panel portrait.
            Circle().strokeBorder(ActionBarMetrics.SourceColor.stroke.swiftUI, lineWidth: 1.5)
        }
        .frame(width: ActionBarMetrics.portraitSide, height: ActionBarMetrics.portraitSide)
        .contentShape(Circle())
        .onTapGesture(perform: copySessionID)
        .offset(
            x: ActionBarMetrics.portraitCenter.x - ActionBarMetrics.portraitRadius,
            y: ActionBarMetrics.portraitCenter.y - ActionBarMetrics.portraitRadius
        )
    }

    private var strips: some View {
        Group {
            strip(y: ActionBarMetrics.titleStripY) {
                Text(model.sessionChip?.title ?? "Terminal")
                    .font(AppFonts.trackerTitle.swiftUI)
                    .foregroundStyle(ActionBarMetrics.SourceColor.title.swiftUI)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            strip(y: ActionBarMetrics.idStripY) {
                Text(model.sessionChip?.id ?? "")
                    .font(AppFonts.monoSmall.swiftUI)
                    .foregroundStyle(AppPalette.dim.swiftUI)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: copySessionID)
    }

    private func copySessionID() {
        guard let id = model.sessionChip?.id, !id.isEmpty else {
            return
        }
        onCopySessionID(id)
    }

    private func strip<Content: View>(y: CGFloat, @ViewBuilder _ content: () -> Content) -> some View {
        RoundedRectangle(cornerRadius: Token.Radius.hairline)
            .fill(AppPalette.panel.swiftUI)
            .overlay(RoundedRectangle(cornerRadius: Token.Radius.hairline).strokeBorder(ActionBarMetrics.SourceColor.stroke.swiftUI, lineWidth: 1))
            .frame(width: ActionBarMetrics.stripWidth, height: ActionBarMetrics.stripHeight)
            .overlay(alignment: .leading) {
                // The strip starts behind the portrait; its text centres in the part that's
                // actually visible, not across the whole (partly hidden) strip.
                content()
                    .frame(
                        width: ActionBarMetrics.stripWidth - ActionBarMetrics.stripVisibleInset - ActionBarMetrics.stripTrailingPadding,
                        alignment: .center
                    )
                    .offset(x: ActionBarMetrics.stripVisibleInset)
            }
            .offset(x: ActionBarMetrics.stripX, y: y)
    }

    private func slotBar(navState: AppNavigationState) -> some View {
        ForEach(Array(slots(navState: navState).enumerated()), id: \.offset) { index, slot in
            ActionBarSlotButton(slot: slot)
                .offset(x: ActionBarMetrics.slotX(at: index), y: ActionBarMetrics.slotTop)
        }
    }

    private func slots(navState: AppNavigationState) -> [ActionBarSlotSpec] {
        [
            ActionBarSlotSpec(
                symbolName: "sidebar.left",
                tooltip: tooltip(navState.trackerVisible ? "Hide Tracker" : "Show Tracker", Keymap.Command.toggleTracker),
                isActive: navState.trackerVisible,
                action: navState.trackerVisible ? onHideTracker : onShowTracker
            ),
            ActionBarSlotSpec(
                symbolName: "plus.rectangle",
                tooltip: tooltip("New Session", Keymap.Command.newSession),
                isActive: false,
                action: onNewSession
            ),
            ActionBarSlotSpec(
                symbolName: "checklist",
                tooltip: tooltip("Open Quests", Keymap.Command.toggleQuestDock),
                isActive: navState.dockVisible && model.dockContentMode == .quests,
                action: onOpenQuests
            ),
            ActionBarSlotSpec(
                symbolName: "doc.richtext",
                tooltip: tooltip("Open Artifacts", Keymap.Command.toggleDock),
                isActive: navState.dockVisible && model.dockContentMode == .artifacts,
                action: onOpenArtifacts
            ),
            .empty, .empty, .empty, .empty, .empty,
            ActionBarSlotSpec(
                symbolName: "cup.and.saucer",
                tooltip: tooltip("Caffeinate", Keymap.Command.toggleCaffeine),
                isActive: model.caffeineActive,
                action: onToggleCaffeine
            ),
            ActionBarSlotSpec(
                symbolName: "gearshape",
                tooltip: tooltip("Settings", Keymap.Command.settings),
                isActive: false,
                action: onOpenSettings
            ),
        ]
    }
}

struct ActionBarSlotSpec {
    var symbolName: String?
    var tooltip: String = ""
    var isActive: Bool = false
    var action: (() -> Void)?

    static let empty = ActionBarSlotSpec(symbolName: nil)
}

/// One of the 11 slots: normal/active/empty, per `action-bar-button.svg`.
struct ActionBarSlotButton: View {
    let slot: ActionBarSlotSpec
    @State private var isHovered = false

    private var isEmpty: Bool { slot.symbolName == nil }

    var body: some View {
        Group {
            if let action = slot.action, !isEmpty {
                Button(action: action) { content }
                    .buttonStyle(.plain)
                    .onHover { isHovered = $0 }
                    .help(slot.tooltip)
            } else {
                content
            }
        }
        .frame(width: ActionBarMetrics.slotSize, height: ActionBarMetrics.slotSize)
    }

    private var content: some View {
        RoundedRectangle(cornerRadius: Token.Radius.hairline)
            .fill((isEmpty ? ActionBarMetrics.SlotFill.empty : ActionBarMetrics.SlotFill.normal).swiftUI)
            .overlay(
                RoundedRectangle(cornerRadius: Token.Radius.hairline)
                    .strokeBorder(
                        (slot.isActive ? ActionBarMetrics.SlotFill.activeBorder : ActionBarMetrics.SourceColor.stroke).swiftUI,
                        lineWidth: 1
                    )
            )
            .overlay(innerShadow)
            .overlay {
                if let symbolName = slot.symbolName {
                    Image(systemName: symbolName)
                        .font(.system(size: ActionBarMetrics.slotIconSize * 0.6, weight: .medium))
                        .foregroundStyle((isHovered ? AppPalette.activeText : ActionBarMetrics.SourceColor.icon).swiftUI)
                }
            }
    }

    /// `action-bar-button.svg`'s two inner shadows: a 25% brass glow on the active slot, a 10%
    /// black recess on an empty one. Approximated as a soft inner stroke rather than a true
    /// Gaussian inner shadow — SwiftUI has no first-class primitive for one.
    @ViewBuilder
    private var innerShadow: some View {
        let shape = RoundedRectangle(cornerRadius: Token.Radius.hairline)
        if slot.isActive {
            shape.strokeBorder(ActionBarMetrics.SlotFill.activeBorder.swiftUI.opacity(0.25), lineWidth: 4)
                .blur(radius: 2)
                .clipShape(shape)
        } else if isEmpty {
            shape.strokeBorder(Color.black.opacity(0.1), lineWidth: 3)
                .blur(radius: 1.5)
                .clipShape(shape)
        }
    }
}

/// Fills and 1.5pt-strokes a literal traced plate outline (`ActionBarPlateOutlines`).
struct ActionBarPlateShapeView: View {
    let path: Path
    let fill: NSColor

    var body: some View {
        ActionBarPlateShape(path: path)
            .fill(fill.swiftUI)
            .overlay(ActionBarPlateShape(path: path).stroke(ActionBarMetrics.SourceColor.stroke.swiftUI, lineWidth: 1.5))
    }
}

private struct ActionBarPlateShape: Shape {
    let path: Path
    func path(in rect: CGRect) -> Path { path }
}
