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
    var onOpenWorkerChat: (() -> Void)?
    var onOpenVersionControl: (() -> Void)?
    var onToggleCaffeine: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    init() {
        hostingView = ActionBarHostingView(rootView: ActionBarFooterView(
            model: model,
            onNewSession: {}, onShowTracker: {}, onHideTracker: {}, onOpenArtifacts: {}, onOpenQuests: {}, onOpenWorkerChat: {}, onOpenVersionControl: {},
            onToggleCaffeine: {}, onOpenSettings: {}
        ))
        super.init(frame: .zero)

        hostingView.rootView = ActionBarFooterView(
            model: model,
            onNewSession: { [weak self] in self?.onNewSession?() },
            onShowTracker: { [weak self] in self?.onShowTracker?() },
            onHideTracker: { [weak self] in self?.onHideTracker?() },
            onOpenArtifacts: { [weak self] in self?.onOpenArtifacts?() },
            onOpenQuests: { [weak self] in self?.onOpenQuests?() },
            onOpenWorkerChat: { [weak self] in self?.onOpenWorkerChat?() },
            onOpenVersionControl: { [weak self] in self?.onOpenVersionControl?() },
            onToggleCaffeine: { [weak self] in self?.onToggleCaffeine?() },
            onOpenSettings: { [weak self] in self?.onOpenSettings?() }
        )

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: topAnchor, constant: -ActionBarMetrics.overflowTop),
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
    /// coordinate convention, so `hitTest`'s rects need no separate flip.
    override var isFlipped: Bool { true }

    /// The footer has no background of its own: the dragon frame is opaque art, and everything else
    /// is transparent. Hit-testing follows the same rule: only the bar and the slots claim a click,
    /// and everything else, including the dragons and the margins, falls through to whatever is
    /// behind (the dock, where the two overlap).
    /// `point` arrives in the superview's coordinates, so it is converted into this view's own (flipped)
    /// space before it is compared with the plate and slot rects.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let contentX = (bounds.width - ActionBarMetrics.plateWidth) / 2
        let platePoint = CGPoint(x: local.x - contentX, y: local.y)
        guard isOnActionBarShape(platePoint) else {
            return nil
        }
        return super.hitTest(point)
    }

    private func isOnActionBarShape(_ point: CGPoint) -> Bool {
        if ActionBarMetrics.barHitRect.contains(point) {
            return true
        }
        return (0..<ActionBarMetrics.slotCount).contains { index in
            CGRect(x: ActionBarMetrics.slotX(at: index), y: ActionBarMetrics.slotTop, width: ActionBarMetrics.slotSize, height: ActionBarMetrics.slotSize).contains(point)
        }
    }

    func update(navigation: AppNavigationState, dockContentMode: DockContentMode) {
        if model.navigation != navigation {
            model.navigation = navigation
        }
        model.dockContentMode = dockContentMode
    }

    func updateCaffeine(_ active: Bool) {
        model.caffeineActive = active
    }
}
