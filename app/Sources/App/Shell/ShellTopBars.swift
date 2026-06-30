import AppKit
import QuestmasterCore
import SwiftUI

/// AppKit pane wrappers that lay out `[SwiftUI top bar | body]` inside the
/// `MainSplitView` split. The chrome (top bars, pills, status leaves) is SwiftUI
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

private func configureSideCard(_ view: NSView) {
    view.wantsLayer = true
    view.layer?.backgroundColor = AppPalette.panel.cgColor
    view.layer?.borderColor = AppPalette.lineSoft.cgColor
    view.layer?.borderWidth = 1
    view.layer?.cornerRadius = ShellMetrics.sideCardCornerRadius
    view.layer?.masksToBounds = true
}

/// Pins a top-bar hosting view above a body view inside `container`.
private func layoutTopBarAndBody(in container: NSView, topBar: NSView, body: NSView) {
    topBar.translatesAutoresizingMaskIntoConstraints = false
    body.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(topBar)
    container.addSubview(body)
    NSLayoutConstraint.activate([
        topBar.topAnchor.constraint(equalTo: container.topAnchor),
        topBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        topBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        topBar.heightAnchor.constraint(equalToConstant: ShellMetrics.topBarHeight),

        body.topAnchor.constraint(equalTo: topBar.bottomAnchor),
        body.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        body.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        body.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
}

final class TrackerShellView: NSView {
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setRegionActive(_ active: Bool) {
        layer?.borderColor = (active ? AppPalette.activeSideCardBorder : AppPalette.lineSoft).cgColor
    }
}

final class TerminalShellView: NSView {
    private let model: TerminalChromeModel
    private let terminalMessageModel: TerminalMessageModel
    private let messageOverlay: NSHostingView<TerminalMessageOverlay>
    var onSelectRegion: ((FocusRegion) -> Void)?
    var onOpenDockMode: ((DockContentMode) -> Void)?

    init(
        body: NSView,
        model: TerminalChromeModel = TerminalChromeModel(),
        terminalMessageModel: TerminalMessageModel = TerminalMessageModel()
    ) {
        self.model = model
        self.terminalMessageModel = terminalMessageModel
        messageOverlay = NSHostingView(rootView: TerminalMessageOverlay(title: "", detail: ""))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = AppPalette.terminal.cgColor

        let topBar = FirstMouseHostingView(rootView: TerminalTopBar(
            model: model,
            onSelectRegion: { [weak self] region in self?.onSelectRegion?(region) },
            onOpenDockMode: { [weak self] mode in self?.onOpenDockMode?(mode) }
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
        model.navigation = navigation
        model.sessionChip = session
    }

    func updateServeStatus(_ state: ServeConnectionState) {
        model.serveState = state
    }

    func showMessage(title: String, detail: String) {
        terminalMessageModel.show(title: title, detail: detail)
        messageOverlay.rootView = TerminalMessageOverlay(title: title, detail: detail)
        messageOverlay.isHidden = false
    }

    func clearMessage() {
        terminalMessageModel.clear()
        messageOverlay.isHidden = true
    }
}

final class DockShellView: NSView {
    private let model: DockChromeModel
    var onHideDock: (() -> Void)?
    var onSelectSection: ((QuestBoardSection) -> Void)?
    var onQuestBack: (() -> Void)?
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
                case .questList: self?.onQuestBack?()
                case .artifactList: self?.onArtifactBack?()
                }
            },
            onSelectSection: { [weak self] section in self?.onSelectSection?(section) },
            onCopyArtifactPath: { [weak self] in self?.onCopyArtifactPath?() },
            onRefreshArtifact: { [weak self] in self?.onRefreshArtifact?() },
            onHideDock: { [weak self] in self?.onHideDock?() }
        ))
        layoutTopBarAndBody(in: self, topBar: topBar, body: body)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setRegionActive(_ active: Bool) {
        layer?.borderColor = (active ? AppPalette.activeSideCardBorder : AppPalette.lineSoft).cgColor
    }

    func updateTabs(
        snapshot: RuntimeSnapshot?,
        selectedSection: QuestBoardSection,
        mode: DockContentMode,
        questRoute: QuestDockRoute,
        questTitle: String?,
        artifactRoute: ArtifactDockRoute,
        artifactTitle: String?
    ) {
        model.topBar = DockTopBarModel.make(
            snapshot: snapshot,
            selectedSection: selectedSection,
            mode: mode,
            questRoute: questRoute,
            questTitle: questTitle,
            artifactRoute: artifactRoute,
            artifactTitle: artifactTitle
        )
    }
}
