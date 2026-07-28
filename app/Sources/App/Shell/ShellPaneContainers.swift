import AppKit
import QuestmasterCore
import SwiftUI

/// AppKit pane wrappers that lay out `[SwiftUI top bar | body]` inside the
/// `MainSplitView` split. The chrome (top bars, status leaves) is SwiftUI
/// hosted via `NSHostingView`; the wrapper stays AppKit because it owns the pane
/// frame, the side-card background/border, and the body island (terminal /
/// SwiftUI host). Public update methods write to the SwiftUI `@Observable` models.

/// Hosting view for the top-bar chrome that accepts the first mouse click, so a
/// single click on a pill / icon button works even when the app isn't frontmost —
/// matching the former AppKit controls (and `SwiftUIDockPane`).
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

private final class NonInteractiveHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private func configureSideCard(_ view: NSView) {
    view.wantsLayer = true
    view.layer?.backgroundColor = AppPalette.panel.cgColor
    view.layer?.borderColor = AppPalette.lineSoftSubtle.cgColor
    view.layer?.borderWidth = 1
    view.layer?.cornerRadius = ShellMetrics.sideCardCornerRadius
    view.layer?.masksToBounds = true
}

/// Pins a top-bar hosting view above a body view inside `container`.
private func layoutTopBarAndBody(
    in container: NSView,
    topBar: NSView,
    body: NSView,
    topBarHeight: CGFloat = ShellMetrics.topBarHeight
) {
    topBar.translatesAutoresizingMaskIntoConstraints = false
    body.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(topBar)
    container.addSubview(body)
    NSLayoutConstraint.activate([
        topBar.topAnchor.constraint(equalTo: container.topAnchor),
        topBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        topBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        topBar.heightAnchor.constraint(equalToConstant: topBarHeight),

        body.topAnchor.constraint(equalTo: topBar.bottomAnchor),
        body.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        body.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        body.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
}

private func layoutSideCardOrnaments(in container: NSView, ornaments: NSView) {
    ornaments.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(ornaments)
    NSLayoutConstraint.activate([
        ornaments.topAnchor.constraint(equalTo: container.topAnchor),
        ornaments.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        ornaments.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ornaments.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
}

final class TrackerShellView: NSView {
    private let ornaments = NonInteractiveHostingView(rootView: SideCardOrnaments())
    var onNewSession: (() -> Void)?
    var onHideTracker: (() -> Void)?

    init(body: NSView) {
        super.init(frame: .zero)
        configureSideCard(self)
        let topBar = FirstMouseHostingView(rootView: TrackerTopBar(
            onNewSession: { [weak self] in self?.onNewSession?() },
            onHideTracker: { [weak self] in self?.onHideTracker?() }
        ))
        layoutTopBarAndBody(in: self, topBar: topBar, body: body)
        layoutSideCardOrnaments(in: self, ornaments: ornaments)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setRegionActive(_ active: Bool) {
        layer?.borderColor = (active ? AppPalette.activeSideCardBorder : AppPalette.lineSoftSubtle).cgColor
        ornaments.rootView = SideCardOrnaments(active: active)
    }
}

final class TerminalShellView: NSView {
    private let model: TerminalChromeModel
    private let messageOverlay: NSHostingView<TerminalMessageOverlay>
    var onShowTracker: (() -> Void)?
    var onOpenArtifacts: (() -> Void)?
    var onOpenQuests: (() -> Void)?
    var onToggleCaffeine: (() -> Void)?
    var onCopySessionID: ((String) -> Void)?

    init(
        body: NSView,
        model: TerminalChromeModel = TerminalChromeModel()
    ) {
        self.model = model
        messageOverlay = NSHostingView(rootView: TerminalMessageOverlay(title: "", detail: ""))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = AppPalette.terminal.cgColor

        let topBar = FirstMouseHostingView(rootView: TerminalTopBar(
            model: model,
            onShowTracker: { [weak self] in self?.onShowTracker?() },
            onOpenArtifacts: { [weak self] in self?.onOpenArtifacts?() },
            onOpenQuests: { [weak self] in self?.onOpenQuests?() },
            onToggleCaffeine: { [weak self] in self?.onToggleCaffeine?() },
            onCopySessionID: { [weak self] sessionID in self?.onCopySessionID?(sessionID) }
        ))
        layoutTopBarAndBody(in: self, topBar: topBar, body: body)

        messageOverlay.translatesAutoresizingMaskIntoConstraints = false
        messageOverlay.isHidden = true
        addSubview(messageOverlay)
        NSLayoutConstraint.activate([
            messageOverlay.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            messageOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            messageOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            messageOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(navigation: AppNavigationState, session: SelectedSessionChip?) {
        if model.navigation != navigation {
            model.navigation = navigation
        }
        if model.sessionChip != session {
            model.sessionChip = session
        }
    }

    func updateCaffeine(_ active: Bool) {
        model.caffeineActive = active
    }

    func showMessage(title: String, detail: String) {
        messageOverlay.rootView = TerminalMessageOverlay(title: title, detail: detail)
        messageOverlay.isHidden = false
    }

    func clearMessage() {
        messageOverlay.isHidden = true
    }
}

final class DockShellView: NSView {
    private let model: DockChromeModel
    private let ornaments = NonInteractiveHostingView(rootView: SideCardOrnaments())
    var onHideDock: (() -> Void)?
    var onArtifactBack: (() -> Void)?
    var onCopyArtifactPath: (() -> Void)?
    var onRefreshArtifact: (() -> Void)?

    init(body: NSView, model: DockChromeModel = DockChromeModel()) {
        self.model = model
        super.init(frame: .zero)
        configureSideCard(self)
        let topBar = FirstMouseHostingView(rootView: DockTopBar(
            model: model,
            onBack: { [weak self] back in
                switch back {
                case .artifactList: self?.onArtifactBack?()
                }
            },
            onCopyArtifactPath: { [weak self] in self?.onCopyArtifactPath?() },
            onRefreshArtifact: { [weak self] in self?.onRefreshArtifact?() },
            onHideDock: { [weak self] in self?.onHideDock?() }
        ))
        layoutTopBarAndBody(
            in: self,
            topBar: topBar,
            body: body,
            topBarHeight: ShellMetrics.dockTopBarHeight
        )
        layoutSideCardOrnaments(in: self, ornaments: ornaments)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setRegionActive(_ active: Bool) {
        layer?.borderColor = (active ? AppPalette.activeSideCardBorder : AppPalette.lineSoftSubtle).cgColor
        ornaments.rootView = SideCardOrnaments(active: active)
    }

    func updateTabs(
        mode: DockContentMode,
        artifactRoute: ArtifactDockRoute,
        artifactTitle: String?
    ) {
        ornaments.isHidden = mode == .artifacts && artifactRoute == .viewer
        let next = DockTopBarModel.make(
            mode: mode,
            artifactRoute: artifactRoute,
            artifactTitle: artifactTitle
        )
        guard model.topBar != next else {
            return
        }
        model.topBar = next
    }
}
