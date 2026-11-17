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
    let onOpenWatcher: () -> Void
    let onToggleCaffeine: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        let navState = model.navigation
        let artifactsOpen = model.dockPanels.bottom && model.dockContentMode == .artifacts
        let workerChatOpen = model.dockPanels.bottom && model.dockContentMode == .workerChat
        HStack(spacing: 0) {
            ActionBarButton(spec: ActionBarButtonSpec(
                icon: .trackerBanner,
                tooltip: tooltip(navState.trackerVisible ? "Hide Tracker" : "Show Tracker", Keymap.Command.toggleTracker),
                isActive: navState.trackerVisible,
                action: navState.trackerVisible ? onHideTracker : onShowTracker
            ))
            Spacer(minLength: 0)
            HStack(spacing: ActionBarMetrics.groupGap) {
                group([
                    ActionBarButtonSpec(icon: .newSessionHelm, tooltip: tooltip("New Session", Keymap.Command.newSession), action: onNewSession),
                    ActionBarButtonSpec(icon: .questLogScroll, tooltip: tooltip("Quest Log", Keymap.Command.toggleQuestLog), action: onOpenQuests),
                    ActionBarButtonSpec(icon: .newQuestScrollQuill, tooltip: tooltip("New Quest", Keymap.Command.newQuest), action: onOpenNewQuest),
                    ActionBarButtonSpec(icon: .settingsCog, tooltip: tooltip("Settings", Keymap.Command.settings), action: onOpenSettings),
                ])
                group([
                    ActionBarButtonSpec(
                        icon: .artifactsBedrollPack,
                        tooltip: tooltip("Open Artifacts", Keymap.Command.toggleDock),
                        isActive: artifactsOpen,
                        action: onOpenArtifacts
                    ),
                    ActionBarButtonSpec(
                        icon: .workerLogConversation,
                        tooltip: tooltip("Open Worker Log", Keymap.Command.toggleWorkerChatDock),
                        isActive: workerChatOpen,
                        action: onOpenWorkerChat
                    ),
                    ActionBarButtonSpec(
                        icon: .watcherEye,
                        tooltip: tooltip("Open Watcher", Keymap.Command.toggleWatcherDock),
                        isActive: model.dockPanels.top,
                        action: onOpenWatcher
                    ),
                ])
            }
            ActionBarButton(spec: ActionBarButtonSpec(
                icon: .keepAwakeBolt,
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

/// One button, drawn from its `ActionBarButtonLook`: the look's fill and border, its icon in the look's colour and drawing,
/// and on a toggle that is on, the brass inner glow with the working spinner turning round the border. The view only
/// tracks the pointer; the look decides what each state shows.
struct ActionBarButton: View {
    let spec: ActionBarButtonSpec
    @State private var isHovered: Bool

    /// `startsHovered` lets a render fixture draw a button under the pointer without a mouse.
    init(spec: ActionBarButtonSpec, startsHovered: Bool = false) {
        self.spec = spec
        _isHovered = State(initialValue: startsHovered)
    }

    var body: some View {
        let look = ActionBarButtonLook.of(active: spec.isActive, on: spec.isOn, hovered: isHovered)
        let shape = RoundedRectangle(cornerRadius: ActionBarMetrics.buttonRadius)
        Button(action: spec.action) {
            shape.fill(look.fill.color.swiftUI)
                .overlay { OnLookGlow(look: look.on, shape: AnyShape(shape), band: Token.Size.glowRing) }
                .overlay(shape.strokeBorder(look.border.color.swiftUI, lineWidth: 1))
                .overlay {
                    OnLookSpinner(look: look.on, cornerRadius: ActionBarMetrics.buttonRadius, stroke: ActionBarMetrics.spinnerStroke)
                }
                .overlay {
                    if let image = spec.icon.image(
                        glyphSide: ActionBarMetrics.iconSide,
                        tint: look.icon.color,
                        filled: look.filled
                    ) {
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
