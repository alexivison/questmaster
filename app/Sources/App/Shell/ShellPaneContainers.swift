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
    topBarHeight: CGFloat
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

/// The tracker column has no chrome: no title bar, border or background, only the window
/// background behind the list and enough top inset to keep the window controls clear of it.
final class TrackerShellView: NSView {
    init(body: NSView) {
        super.init(frame: .zero)
        body.translatesAutoresizingMaskIntoConstraints = false
        addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: topAnchor, constant: ShellMetrics.trackerTopInset),
            body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// A thin strip pinned to the top of the terminal pane that lets the window be dragged by its
/// background, the way the removed header used to. With the header gone the terminal's own view
/// now reaches the window's top edge, under the transparent titlebar; its own `mouseDown` (text
/// selection) would otherwise swallow drags there, since `NSView.mouseDownCanMoveWindow` only
/// kicks in when nothing else handles the event first.
private final class WindowDragHandleView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}

final class TerminalShellView: NSView {
    private let messageOverlay: NSHostingView<TerminalMessageOverlay>

    init(body: NSView, dragHandleHeight: CGFloat) {
        messageOverlay = NSHostingView(rootView: TerminalMessageOverlay(title: "", detail: ""))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = AppPalette.terminal.cgColor

        body.translatesAutoresizingMaskIntoConstraints = false
        addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: topAnchor),
            body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let dragHandle = WindowDragHandleView()
        dragHandle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dragHandle)
        NSLayoutConstraint.activate([
            dragHandle.topAnchor.constraint(equalTo: topAnchor),
            dragHandle.leadingAnchor.constraint(equalTo: leadingAnchor),
            dragHandle.trailingAnchor.constraint(equalTo: trailingAnchor),
            dragHandle.heightAnchor.constraint(equalToConstant: dragHandleHeight),
        ])

        messageOverlay.translatesAutoresizingMaskIntoConstraints = false
        messageOverlay.isHidden = true
        addSubview(messageOverlay)
        NSLayoutConstraint.activate([
            messageOverlay.topAnchor.constraint(equalTo: topAnchor),
            messageOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            messageOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            messageOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
