import AppKit
import QuestmasterCore
import SwiftUI

/// The action bar header over the terminal column: the tracker toggle at the leading end and the grouped buttons at
/// the trailing end, on the scooped panel `ActionBarShellView` draws. See `ActionBarMetrics` for the geometry and
/// `ActionBarButtonLook` for the states.

private func tooltip(_ label: String, _ binding: Keymap.CommandBinding) -> String {
    "\(label)  \(binding.displayGlyph)"
}

@Observable
final class ActionBarModel {
    var navigation: AppNavigationState
    var caffeineActive: Bool
    /// The bottom panel's content: artifacts or the worker chat.
    var dockContentMode: DockContentMode
    var dockPanels: DockPanels

    init(
        navigation: AppNavigationState = AppNavigationState(),
        caffeineActive: Bool = false,
        dockContentMode: DockContentMode = .artifacts,
        dockPanels: DockPanels = DockPanels()
    ) {
        self.navigation = navigation
        self.caffeineActive = caffeineActive
        self.dockContentMode = dockContentMode
        self.dockPanels = dockPanels
    }
}

struct ActionBarView: View {
    let model: ActionBarModel
    let onNewSession: () -> Void
    let onShowTracker: () -> Void
    let onHideTracker: () -> Void
    let onOpenArtifacts: () -> Void
    let onOpenQuests: () -> Void
    let onOpenNewQuest: () -> Void
    let onOpenWorkerChat: () -> Void
    let onOpenVersionControl: () -> Void
    let onToggleCaffeine: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        let navState = model.navigation
        let artifactsOpen = model.dockPanels.bottom && model.dockContentMode == .artifacts
        let workerChatOpen = model.dockPanels.bottom && model.dockContentMode == .workerChat
        HStack(spacing: 0) {
            ActionBarButton(spec: ActionBarButtonSpec(
                icon: .trackerToggle,
                tooltip: tooltip(navState.trackerVisible ? "Hide Tracker" : "Show Tracker", Keymap.Command.toggleTracker),
                isActive: navState.trackerVisible,
                action: navState.trackerVisible ? onHideTracker : onShowTracker
            ))
            Spacer(minLength: 0)
            HStack(spacing: ActionBarMetrics.groupGap) {
                group([
                    ActionBarButtonSpec(icon: .newSession, tooltip: tooltip("New Session", Keymap.Command.newSession), action: onNewSession),
                    ActionBarButtonSpec(icon: .questLog, tooltip: tooltip("Quest Log", Keymap.Command.toggleQuestLog), action: onOpenQuests),
                    ActionBarButtonSpec(icon: .newQuest, tooltip: tooltip("New Quest", Keymap.Command.newQuest), action: onOpenNewQuest),
                    ActionBarButtonSpec(icon: .settings, tooltip: tooltip("Settings", Keymap.Command.settings), action: onOpenSettings),
                ])
                group([
                    ActionBarButtonSpec(
                        icon: .artifacts,
                        tooltip: tooltip("Open Artifacts", Keymap.Command.toggleDock),
                        isActive: artifactsOpen,
                        action: onOpenArtifacts
                    ),
                    ActionBarButtonSpec(
                        icon: .workerLog,
                        tooltip: tooltip("Open Worker Log", Keymap.Command.toggleWorkerChatDock),
                        isActive: workerChatOpen,
                        action: onOpenWorkerChat
                    ),
                    ActionBarButtonSpec(
                        icon: .versionControl,
                        tooltip: tooltip("Open Version Control", Keymap.Command.toggleVersionControlDock),
                        isActive: model.dockPanels.top,
                        action: onOpenVersionControl
                    ),
                ])
            }
            ActionBarButton(spec: ActionBarButtonSpec(
                icon: .caffeinate,
                tooltip: tooltip("Caffeinate", Keymap.Command.toggleCaffeine),
                isOn: model.caffeineActive,
                action: onToggleCaffeine
            ))
            .padding(.leading, ActionBarMetrics.toggleGap)
        }
        .padding(.horizontal, ActionBarMetrics.endInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WindowDragArea())
        // The header sits under the window's transparent titlebar, whose safe area would push the buttons down.
        .ignoresSafeArea()
    }

    private func group(_ specs: [ActionBarButtonSpec]) -> some View {
        HStack(spacing: ActionBarMetrics.buttonSeam) {
            ForEach(specs.indices, id: \.self) { ActionBarButton(spec: specs[$0]) }
        }
    }
}

struct ActionBarButtonSpec {
    let icon: AppIcon
    let tooltip: String
    /// What it opens shows (the tracker, a dock panel).
    var isActive = false
    /// A toggle that is on (caffeinate).
    var isOn = false
    let action: () -> Void
}

/// One button, per the design: an `item` square with a `line` border, its icon in the look's colour, and on a toggle
/// that is on, the brass inner glow with the working spinner turning round the border.
struct ActionBarButton: View {
    let spec: ActionBarButtonSpec
    @State private var isHovered = false

    var body: some View {
        let look = ActionBarButtonLook.of(active: spec.isActive, on: spec.isOn, hovered: isHovered)
        let shape = RoundedRectangle(cornerRadius: ActionBarMetrics.buttonRadius)
        Button(action: spec.action) {
            shape.fill(AppPalette.item.swiftUI)
                .overlay(shape.strokeBorder(AppPalette.brassActive.swiftUI.opacity(look.glowOpacity), lineWidth: ActionBarMetrics.glowRing))
                .overlay(shape.strokeBorder(AppPalette.line.swiftUI, lineWidth: 1))
                .overlay {
                    if look.spins {
                        SpinnerRingView(stroke: ActionBarMetrics.spinnerStroke, cornerRadius: ActionBarMetrics.buttonRadius)
                    }
                }
                .overlay {
                    if let image = spec.icon.image(glyphSide: ActionBarMetrics.iconSide, tint: look.icon.color) {
                        Image(nsImage: image)
                    }
                }
        }
        .buttonStyle(.plain)
        .frame(width: ActionBarMetrics.buttonSize, height: ActionBarMetrics.buttonSize)
        .onHover { isHovered = $0 }
        .help(spec.tooltip)
    }
}

/// The header's empty space moves the window, as the titlebar strip it covers would.
private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}
