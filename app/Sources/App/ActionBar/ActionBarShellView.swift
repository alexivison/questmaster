import AppKit
import QuestmasterCore
import SwiftUI

/// Hosts `ActionBarView`, accepting the first click on its buttons even while the window is
/// inactive.
private final class ActionBarHostingView: NSHostingView<ActionBarView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

/// The header's AppKit host: the dock panels' scooped chrome (fill, border and shadow) at the header's own radius,
/// around the SwiftUI bar. `MainSplitView` lays it out over the terminal column.
final class ActionBarShellView: NSView {
    private let model = ActionBarModel()
    private let hostingView: ActionBarHostingView
    private var chrome: ScoopedLayerChrome!

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
        hostingView = ActionBarHostingView(rootView: ActionBarView(
            model: model,
            onNewSession: {}, onShowTracker: {}, onHideTracker: {}, onOpenArtifacts: {}, onOpenQuests: {}, onOpenWorkerChat: {}, onOpenVersionControl: {},
            onToggleCaffeine: {}, onOpenSettings: {}
        ))
        super.init(frame: .zero)

        hostingView.rootView = ActionBarView(
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

        // The split view sets the header's frame; the bar's content mustn't push back on it.
        hostingView.sizingOptions = []
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        chrome = ScoopedLayerChrome(view: self, content: hostingView, radius: ActionBarMetrics.scoopRadius)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        chrome.layout(bounds: bounds)
    }

    func update(navigation: AppNavigationState, dockPanels: DockPanels, dockContentMode: DockContentMode) {
        if model.navigation != navigation {
            model.navigation = navigation
        }
        if model.dockPanels != dockPanels {
            model.dockPanels = dockPanels
        }
        model.dockContentMode = dockContentMode
    }

    func updateCaffeine(_ active: Bool) {
        model.caffeineActive = active
    }
}
