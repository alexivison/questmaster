import AppKit
import QuestmasterCore
import SwiftUI

/// Hosts `ActionBarFooterView`, accepting the first click on its slots even while the window is
/// inactive.
private final class ActionBarHostingView: NSHostingView<ActionBarFooterView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

final class ActionBarShellView: NSView {
    private let model = ActionBarFooterModel()
    private let hostingView: ActionBarHostingView

    var onNewSession: (() -> Void)?
    var onShowTracker: (() -> Void)?
    var onHideTracker: (() -> Void)?
    var onOpenArtifacts: (() -> Void)?
    var onOpenQuests: (() -> Void)?
    var onToggleCaffeine: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onCopySessionID: ((String) -> Void)?

    init() {
        hostingView = ActionBarHostingView(rootView: ActionBarFooterView(
            model: model,
            onNewSession: {}, onShowTracker: {}, onHideTracker: {}, onOpenArtifacts: {}, onOpenQuests: {},
            onToggleCaffeine: {}, onOpenSettings: {}, onCopySessionID: { _ in }
        ))
        super.init(frame: .zero)

        hostingView.rootView = ActionBarFooterView(
            model: model,
            onNewSession: { [weak self] in self?.onNewSession?() },
            onShowTracker: { [weak self] in self?.onShowTracker?() },
            onHideTracker: { [weak self] in self?.onHideTracker?() },
            onOpenArtifacts: { [weak self] in self?.onOpenArtifacts?() },
            onOpenQuests: { [weak self] in self?.onOpenQuests?() },
            onToggleCaffeine: { [weak self] in self?.onToggleCaffeine?() },
            onOpenSettings: { [weak self] in self?.onOpenSettings?() },
            onCopySessionID: { [weak self] sessionID in self?.onCopySessionID?(sessionID) }
        )

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Top-left origin, matching `ActionBarFooterView`'s own SwiftUI (and so `ActionBarMetrics`'s)
    /// coordinate convention — so `hitTest`'s shape maths below doesn't need a separate flip.
    override var isFlipped: Bool { true }

    /// The footer has no background (the window behind it already is `AppPalette.window`, and
    /// painting one would hide the dock, now the window's full height, under the whole strip).
    /// Hit-testing follows the same rule: only the actual plate/slot/pill shapes should claim a
    /// click — everywhere else, including the margins outside the centred content block, must
    /// fall through to whatever is behind (the dock, where the two overlap).
    override func hitTest(_ point: NSPoint) -> NSView? {
        let contentX = (bounds.width - ActionBarMetrics.plateWidth) / 2
        let local = CGPoint(x: point.x - contentX, y: point.y)
        guard isOnActionBarShape(local) else {
            return nil
        }
        return super.hitTest(point)
    }

    private func isOnActionBarShape(_ point: CGPoint) -> Bool {
        if ActionBarPlateOutlines.slotBar.contains(point) || currentPanelPath.contains(point) {
            return true
        }
        return (0..<ActionBarMetrics.slotCount).contains { index in
            CGRect(x: ActionBarMetrics.slotX(at: index), y: ActionBarMetrics.slotTop, width: ActionBarMetrics.slotSize, height: ActionBarMetrics.slotSize).contains(point)
        }
    }

    private var currentPanelPath: Path {
        switch ActionBarSessionPanelVariant(role: model.sessionRole) {
        case .master: ActionBarPlateOutlines.masterPanel
        case .standalone: ActionBarPlateOutlines.standalonePanel
        case .worker: ActionBarPlateOutlines.workerPanel
        }
    }

    func update(
        navigation: AppNavigationState,
        session: SelectedSessionChip?,
        role: SessionRoleKind?,
        dockContentMode: DockContentMode
    ) {
        if model.navigation != navigation {
            model.navigation = navigation
        }
        if model.sessionChip != session {
            model.sessionChip = session
        }
        model.sessionRole = role
        model.dockContentMode = dockContentMode
    }

    func updateCaffeine(_ active: Bool) {
        model.caffeineActive = active
    }
}
