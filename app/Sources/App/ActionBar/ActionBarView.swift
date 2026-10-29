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
                icon: .symbol("sidebar.left"),
                tooltip: tooltip(navState.trackerVisible ? "Hide Tracker" : "Show Tracker", Keymap.Command.toggleTracker),
                isActive: navState.trackerVisible,
                action: navState.trackerVisible ? onHideTracker : onShowTracker
            ))
            Spacer(minLength: 0)
            HStack(spacing: ActionBarMetrics.groupGap) {
                group([
                    ActionBarButtonSpec(icon: .symbol("plus.rectangle"), tooltip: tooltip("New Session", Keymap.Command.newSession), action: onNewSession),
                    ActionBarButtonSpec(icon: .symbol("checklist"), tooltip: tooltip("Quest Log", Keymap.Command.toggleQuestLog), action: onOpenQuests),
                    ActionBarButtonSpec(icon: .symbol("gearshape"), tooltip: tooltip("Settings", Keymap.Command.settings), action: onOpenSettings),
                ])
                group([
                    ActionBarButtonSpec(
                        icon: .symbol("doc.richtext"),
                        tooltip: tooltip("Open Artifacts", Keymap.Command.toggleDock),
                        isActive: artifactsOpen,
                        action: onOpenArtifacts
                    ),
                    ActionBarButtonSpec(
                        icon: .symbol("text.bubble"),
                        tooltip: tooltip("Open Worker Log", Keymap.Command.toggleWorkerChatDock),
                        isActive: workerChatOpen,
                        action: onOpenWorkerChat
                    ),
                    ActionBarButtonSpec(
                        icon: .pullRequest,
                        tooltip: tooltip("Open Version Control", Keymap.Command.toggleVersionControlDock),
                        isActive: model.dockPanels.top,
                        action: onOpenVersionControl
                    ),
                ])
            }
            ActionBarButton(spec: ActionBarButtonSpec(
                icon: .symbol("cup.and.saucer"),
                tooltip: tooltip("Caffeinate", Keymap.Command.toggleCaffeine),
                isOn: model.caffeineActive,
                action: onToggleCaffeine
            ))
            .padding(.leading, ActionBarMetrics.toggleGap)
        }
        .padding(.horizontal, ActionBarMetrics.endInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WindowDragArea())
    }

    private func group(_ specs: [ActionBarButtonSpec]) -> some View {
        HStack(spacing: ActionBarMetrics.buttonSeam) {
            ForEach(specs.indices, id: \.self) { ActionBarButton(spec: specs[$0]) }
        }
    }
}

enum ActionBarIcon {
    case symbol(String)
    /// The design's own pull-request glyph: SF Symbols' `arrow.triangle.pull` draws a different mark.
    case pullRequest
}

struct ActionBarButtonSpec {
    let icon: ActionBarIcon
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
                .overlay { icon.foregroundStyle(look.icon.color.swiftUI) }
        }
        .buttonStyle(.plain)
        .frame(width: ActionBarMetrics.buttonSize, height: ActionBarMetrics.buttonSize)
        .onHover { isHovered = $0 }
        .help(spec.tooltip)
    }

    @ViewBuilder
    private var icon: some View {
        switch spec.icon {
        case .symbol(let name):
            let size = ActionBarMetrics.IconSize.size(for: name)
            Image(systemName: name)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .fontWeight(.medium)
                .frame(width: size.width, height: size.height)
        case .pullRequest:
            PullRequestGlyph()
                .stroke(style: StrokeStyle(lineWidth: PullRequestGlyph.svgStroke, lineCap: .round, lineJoin: .round))
        }
    }
}

/// The pull-request glyph from `Main Chat Header.svg`, in the 30pt button's own coordinates.
private struct PullRequestGlyph: Shape {
    static let svgStroke: CGFloat = 1.5
    private static let svgCircleRadius: CGFloat = 2.1875

    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x, y: rect.minY + y) }
        var path = Path()
        for (x, y) in [(20.625, 20.625), (9.375, 20.625), (9.375, 9.375)] as [(CGFloat, CGFloat)] {
            let r = Self.svgCircleRadius
            path.addEllipse(in: CGRect(x: rect.minX + x - r, y: rect.minY + y - r, width: 2 * r, height: 2 * r))
        }
        path.move(to: point(16.5625, 7.1875))
        path.addLine(to: point(14.6875, 9.6875))
        path.addLine(to: point(16.5625, 12.1875))
        path.move(to: point(20.3125, 17.8125))
        path.addLine(to: point(20.3125, 11.5625))
        path.addCurve(to: point(18.4375, 9.6875), control1: point(20.3125, 10.3125), control2: point(19.6875, 9.6875))
        path.addLine(to: point(15.9375, 9.6875))
        path.move(to: point(9.6875, 12.1875))
        path.addLine(to: point(9.6875, 17.8125))
        return path
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
