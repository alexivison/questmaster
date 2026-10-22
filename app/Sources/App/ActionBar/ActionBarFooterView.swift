import AppKit
import QuestmasterCore
import SwiftUI

/// The RPG-style action bar footer: the design's dragon frame with eleven slots across it. The
/// frame is the design's own art (`action-bar-frame.svg`); the slots are live buttons. See
/// `ActionBarMetrics` for the geometry.

private func tooltip(_ label: String, _ binding: Keymap.CommandBinding) -> String {
    "\(label)  \(binding.displayGlyph)"
}

@Observable
final class ActionBarFooterModel {
    var navigation: AppNavigationState
    var caffeineActive: Bool
    var dockContentMode: DockContentMode

    init(
        navigation: AppNavigationState = AppNavigationState(),
        caffeineActive: Bool = false,
        dockContentMode: DockContentMode = .artifacts
    ) {
        self.navigation = navigation
        self.caffeineActive = caffeineActive
        self.dockContentMode = dockContentMode
    }
}

struct ActionBarFooterView: View {
    let model: ActionBarFooterModel
    let onNewSession: () -> Void
    let onShowTracker: () -> Void
    let onHideTracker: () -> Void
    let onOpenArtifacts: () -> Void
    let onOpenQuests: () -> Void
    let onOpenWorkerChat: () -> Void
    let onToggleCaffeine: () -> Void
    let onOpenSettings: () -> Void

    private static let frameImage = AppSymbolStyle.resourceImage(
        name: "action-bar-frame",
        fileExtension: "svg",
        subdirectory: "ActionBar",
        canvasSize: NSSize(width: ActionBarMetrics.plateWidth, height: ActionBarMetrics.canvasHeight)
    )

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let frame = Self.frameImage {
                Image(nsImage: frame)
                    .resizable()
                    .frame(width: ActionBarMetrics.plateWidth, height: ActionBarMetrics.canvasHeight)
            }
            slotBar(navState: model.navigation)
        }
        .frame(width: ActionBarMetrics.plateWidth, height: ActionBarMetrics.canvasHeight, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func slotBar(navState: AppNavigationState) -> some View {
        ForEach(Array(slots(navState: navState).enumerated()), id: \.offset) { index, slot in
            ActionBarSlotButton(slot: slot)
                .offset(x: ActionBarMetrics.slotX(at: index), y: ActionBarMetrics.slotTop + ActionBarMetrics.overflowTop)
        }
    }

    /// The eleven slots, left to right. The worker chat keeps its place in the first empty slot after
    /// new session until the design settles its slot; the other empty slots are placeholders.
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
                symbolName: "bubble.left.and.bubble.right",
                tooltip: tooltip("Open Worker Chat", Keymap.Command.toggleWorkerChatDock),
                isActive: navState.dockVisible && model.dockContentMode == .workerChat,
                action: onOpenWorkerChat
            ),
            .empty, .empty, .empty, .empty,
            ActionBarSlotSpec(
                symbolName: "checklist",
                tooltip: tooltip("Quest Log", Keymap.Command.toggleQuestLog),
                isActive: false,
                action: onOpenQuests
            ),
            ActionBarSlotSpec(
                symbolName: "gearshape",
                tooltip: tooltip("Settings", Keymap.Command.settings),
                isActive: false,
                action: onOpenSettings
            ),
            ActionBarSlotSpec(
                symbolName: "doc.richtext",
                tooltip: tooltip("Open Artifacts", Keymap.Command.toggleDock),
                isActive: navState.dockVisible && model.dockContentMode == .artifacts,
                action: onOpenArtifacts
            ),
            ActionBarSlotSpec(
                symbolName: "cup.and.saucer",
                tooltip: tooltip("Caffeinate", Keymap.Command.toggleCaffeine),
                isActive: model.caffeineActive,
                action: onToggleCaffeine
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

/// One of the eleven slots: normal, active, or empty, per the design's `action-bar-button.svg`.
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

    private var toggle: ToggleLook { .of(on: slot.isActive) }

    private var content: some View {
        RoundedRectangle(cornerRadius: Token.Radius.hairline)
            .fill((isEmpty ? ActionBarMetrics.SlotFill.empty : ActionBarMetrics.SlotFill.normal).swiftUI)
            .overlay(
                RoundedRectangle(cornerRadius: Token.Radius.hairline)
                    .strokeBorder(toggle.border.color.swiftUI, lineWidth: 1)
            )
            .overlay(innerShadow)
            .overlay {
                if let symbolName = slot.symbolName {
                    let iconSize = ActionBarMetrics.SlotIconSize.size(for: symbolName)
                    Image(systemName: symbolName)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .fontWeight(.medium)
                        .frame(width: iconSize.width, height: iconSize.height)
                        .foregroundStyle((isHovered ? AppPalette.bright : AppPalette.dim).swiftUI)
                }
            }
    }

    /// The design's two inner shadows: a 25% brass glow on the active slot, a 10% black recess on an
    /// empty one. Approximated as a soft inner stroke, since SwiftUI has no inner-shadow primitive.
    @ViewBuilder
    private var innerShadow: some View {
        let shape = RoundedRectangle(cornerRadius: Token.Radius.hairline)
        if toggle.glowOpacity > 0 {
            shape.strokeBorder(toggle.border.color.swiftUI.opacity(toggle.glowOpacity), lineWidth: 4)
                .blur(radius: 2)
                .clipShape(shape)
        } else if isEmpty {
            shape.strokeBorder(AppPalette.shadow.swiftUI.opacity(0.1), lineWidth: 3)
                .blur(radius: 1.5)
                .clipShape(shape)
        }
    }
}
