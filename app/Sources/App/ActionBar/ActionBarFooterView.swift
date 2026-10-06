import AppKit
import QuestmasterCore
import SwiftUI

/// The RPG-style action bar footer: a full-width strip at the bottom of the window replacing the
/// old `TerminalTopBar`, built the way the tracker builds its nameplates — shapes from the design's
/// SVG paths, unioned at runtime (`TrackerPlatePaths.mainPlate`). See `ActionBarMetrics` for the
/// geometry and the off-palette colour mapping, and `app/Sources/Core/ActionBar` for the pure
/// worker-strip/truncation/keymap logic this view reads.

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
        VStack(alignment: .leading, spacing: ActionBarMetrics.plateToStripGap) {
            plateZone(navState: navState)
            ActionBarWorkerStripView(
                workers: model.workers,
                highlightedWorkerID: model.highlightedWorkerID,
                state: model.workerStripState,
                onAttach: onAttachWorker,
                onScroll: { side in
                    model.workerStripState.scroll(
                        toward: side,
                        workerCount: model.workers.count,
                        visibleCount: ActionBarMetrics.worker.visibleCount
                    )
                }
            )
        }
        .frame(width: ActionBarMetrics.plateWidth, height: ActionBarMetrics.footerHeight, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .center)
        .frame(height: ActionBarMetrics.footerHeight)
        .background(AppPalette.window.swiftUI)
    }

    private func plateZone(navState: AppNavigationState) -> some View {
        ZStack(alignment: .topLeading) {
            ActionBarPlateBackground(variant: panelVariant)
            ActionBarSessionPanelContent(
                variant: panelVariant,
                title: model.sessionChip?.title ?? "Terminal",
                sessionID: model.sessionChip?.id ?? "",
                agent: model.sessionChip?.agent ?? ""
            )
            .contentShape(Rectangle())
            .onTapGesture { copySessionID() }
            slotBar(navState: navState)
        }
        .frame(width: ActionBarMetrics.plateWidth, height: ActionBarMetrics.plateZoneHeight, alignment: .topLeading)
    }

    private var panelVariant: ActionBarSessionPanelVariant {
        ActionBarSessionPanelVariant(role: model.sessionRole)
    }

    private func copySessionID() {
        guard let id = model.sessionChip?.id, !id.isEmpty else {
            return
        }
        onCopySessionID(id)
    }

    private func slotBar(navState: AppNavigationState) -> some View {
        ForEach(Array(slots(navState: navState).enumerated()), id: \.offset) { index, slot in
            ActionBarSlotButton(slot: slot)
                .offset(x: ActionBarMetrics.slotX(at: index), y: (ActionBarMetrics.barTop + ActionBarMetrics.barBottom - ActionBarMetrics.slotSize) / 2)
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

/// The big plate's background fill + 1.5pt outer border, per the brief: "the outline around the
/// main plate (session panel plus slot bar)".
struct ActionBarPlateBackground: View {
    let variant: ActionBarSessionPanelVariant

    private var capKind: TrackerPlatePaths.Kind {
        switch variant {
        case .master: .master
        case .standalone: .standalone
        case .worker: .worker
        }
    }

    private var capSize: CGSize {
        variant == .master ? ActionBarMetrics.masterCapSize : ActionBarMetrics.circleCapSize
    }

    private var path: Path {
        TrackerPlatePaths.mainPlate(
            capKind: capKind,
            capSize: capSize,
            barTop: ActionBarMetrics.barTop,
            barBottom: ActionBarMetrics.barBottom,
            rightEdgeX: ActionBarMetrics.plateWidth
        )
    }

    var body: some View {
        ActionBarPlateShape(path: path)
            .fill(AppPalette.item.swiftUI)
            .overlay(ActionBarPlateShape(path: path).stroke(ActionBarMetrics.SourceColor.stroke.swiftUI, lineWidth: 1.5))
    }
}

private struct ActionBarPlateShape: Shape {
    let path: Path
    func path(in rect: CGRect) -> Path { path }
}

/// The portrait + title/ID strips, drawn over the plate background.
struct ActionBarSessionPanelContent: View {
    let variant: ActionBarSessionPanelVariant
    let title: String
    let sessionID: String
    let agent: String

    private var capWidth: CGFloat {
        variant == .master ? ActionBarMetrics.masterCapSize.width : ActionBarMetrics.circleCapSize.width
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            portrait
            strips
        }
    }

    private var portrait: some View {
        ZStack {
            Circle().fill(AppPalette.panel.swiftUI)
            if let image = TrackerAgentMark.image(for: agent, side: ActionBarMetrics.portraitSide * 0.615, tint: ActionBarMetrics.SourceColor.logo) {
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
        .offset(x: ActionBarMetrics.portraitLeft(capWidth: capWidth), y: ActionBarMetrics.portraitTop)
    }

    private var strips: some View {
        VStack(spacing: -ActionBarMetrics.stripOverlap) {
            strip(height: ActionBarMetrics.titleStripHeight) {
                Text(title)
                    .font(AppFonts.trackerTitle.swiftUI)
                    .foregroundStyle(ActionBarMetrics.SourceColor.title.swiftUI)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            strip(height: ActionBarMetrics.idStripHeight) {
                Text(sessionID)
                    .font(AppFonts.monoSmall.swiftUI)
                    .foregroundStyle(AppPalette.dim.swiftUI)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(width: ActionBarMetrics.titleIDStripWidth)
        .offset(
            x: ActionBarMetrics.stripZoneX,
            y: (ActionBarMetrics.barTop + ActionBarMetrics.barBottom - (ActionBarMetrics.titleStripHeight + ActionBarMetrics.idStripHeight - ActionBarMetrics.stripOverlap)) / 2
        )
    }

    private func strip<Content: View>(height: CGFloat, @ViewBuilder _ content: () -> Content) -> some View {
        RoundedRectangle(cornerRadius: Token.Radius.hairline)
            .fill(AppPalette.panel.swiftUI)
            .overlay(RoundedRectangle(cornerRadius: Token.Radius.hairline).strokeBorder(ActionBarMetrics.SourceColor.stroke.swiftUI, lineWidth: 1))
            .overlay(alignment: .leading) {
                content()
                    .padding(.leading, ActionBarMetrics.stripLeadingPadding)
                    .padding(.trailing, ActionBarMetrics.stripTrailingPadding)
            }
            .frame(height: height)
    }
}
