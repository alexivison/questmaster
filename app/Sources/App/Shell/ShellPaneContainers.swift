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
    private let messageOverlay: NSHostingView<TerminalEndedOverlay>

    init(body: NSView, dragHandleHeight: CGFloat) {
        messageOverlay = NSHostingView(rootView: TerminalEndedOverlay())
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

    /// Whether the ended-session icon is up.
    var showsEnded: Bool { !messageOverlay.isHidden }

    func showEnded() {
        messageOverlay.isHidden = false
    }

    func clearEnded() {
        messageOverlay.isHidden = true
    }
}

final class DockShellView: NSView {
    private let model: DockChromeModel
    private var chrome: ScoopedLayerChrome!
    var onHideDock: (() -> Void)?
    var onArtifactBack: (() -> Void)?
    var onCopyArtifactPath: (() -> Void)?
    var onRefreshArtifact: (() -> Void)?
    var onToggleLogFilter: (() -> Void)?
    var onDismissLogFilter: (() -> Void)?

    init(body: NSView, model: DockChromeModel = DockChromeModel()) {
        self.model = model
        super.init(frame: .zero)
        let topBar = FirstMouseHostingView(rootView: DockTopBar(
            model: model,
            onBack: { [weak self] back in
                switch back {
                case .artifactList: self?.onArtifactBack?()
                }
            },
            onCopyArtifactPath: { [weak self] in self?.onCopyArtifactPath?() },
            onRefreshArtifact: { [weak self] in self?.onRefreshArtifact?() },
            onToggleLogFilter: { [weak self] in self?.onToggleLogFilter?() },
            onDismissLogFilter: { [weak self] in self?.onDismissLogFilter?() },
            onHideDock: { [weak self] in self?.onHideDock?() }
        ))
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        layoutTopBarAndBody(
            in: content,
            topBar: topBar,
            body: body,
            topBarHeight: ShellMetrics.dockTopBarHeight
        )
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        chrome = ScoopedLayerChrome(view: self, content: content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        chrome?.layout(bounds: bounds)
    }

    private(set) var isFocused = false

    /// The 2pt frame lifts one step while the dock has keyboard focus.
    func setFocused(_ focused: Bool) {
        isFocused = focused
        chrome.setBorderColor(OutlineLook.frame(focused: focused).border.color)
    }

    func updateTabs(
        mode: DockContentMode,
        artifactRoute: ArtifactDockRoute,
        artifactTitle: String?,
        logAttached: Bool
    ) {
        let next = DockTopBarModel.make(
            mode: mode,
            artifactRoute: artifactRoute,
            artifactTitle: artifactTitle,
            logAttached: logAttached
        )
        guard model.topBar != next else {
            return
        }
        model.topBar = next
    }
}

/// The dock region: Version Control's panel over the bottom panel (artifacts or worker chat), each its own scooped
/// `DockShellView`, laid out by `DockColumnLayout`. It's the pane `MainSplitView` sizes and shows or hides; what shows
/// inside follows the dock state's panels.
///
/// While the dock stays on screen, a panel appearing or going away is a short one-shot transition (`DockPanelMotion`): it
/// fades as it slides in from its edge or back out, and the other panel grows or shrinks to its new slot, frame by frame,
/// so its chrome stays whole. The first panel showing and the last one hiding belong to `MainSplitView`, which fades and
/// slides the whole column. Reduce Motion skips all of it.
final class DockColumnView: NSView {
    let topShell: DockShellView
    let bottomShell: DockShellView
    private var panels = DockPanels()
    private var transition: Transition?

    private struct Transition {
        let from: DockColumnLayout
        let to: DockColumnLayout
        let began: CFTimeInterval
        let timer: Timer
    }

    init(top: DockShellView, bottom: DockShellView) {
        topShell = top
        bottomShell = bottom
        super.init(frame: .zero)
        addSubview(top)
        addSubview(bottom)
        top.isHidden = true
        bottom.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var isTransitioning: Bool {
        transition != nil
    }

    func setPanels(_ next: DockPanels, animated: Bool = false) {
        guard panels != next else {
            return
        }
        finishTransition()
        let previous = panels
        panels = next
        guard animated, window != nil, previous.isShown, next.isShown, !Motion.reducesMotion() else {
            needsLayout = true
            return
        }
        beginTransition(from: previous, to: next)
    }

    override func layout() {
        super.layout()
        guard transition == nil else {
            return
        }
        let layout = DockColumnLayout.make(height: Double(bounds.height), panels: panels)
        place(topShell, DockPanelFrame(slot: layout.top))
        place(bottomShell, DockPanelFrame(slot: layout.bottom))
    }

    private func beginTransition(from previous: DockPanels, to next: DockPanels) {
        let height = Double(bounds.height)
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            self?.step()
        }
        RunLoop.main.add(timer, forMode: .common)
        let running = Transition(
            from: DockColumnLayout.make(height: height, panels: previous),
            to: DockColumnLayout.make(height: height, panels: next),
            began: CACurrentMediaTime(),
            timer: timer
        )
        transition = running
        apply(running, progress: 0)
    }

    private func step() {
        guard let running = transition else {
            return
        }
        let progress = min(1, (CACurrentMediaTime() - running.began) / Motion.duration(.standard))
        guard progress < 1 else {
            finishTransition()
            return
        }
        apply(running, progress: MotionEasing.eased(progress))
    }

    private func apply(_ running: Transition, progress: Double) {
        let frames = DockColumnTransition.make(from: running.from, to: running.to, progress: progress)
        place(topShell, frames.top)
        place(bottomShell, frames.bottom)
    }

    /// Ends a running transition at its target: every panel at its slot, fully shown, the others hidden.
    private func finishTransition() {
        guard let running = transition else {
            return
        }
        running.timer.invalidate()
        transition = nil
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    /// A panel without a frame hides; the others sit at their offset down from the column's top edge.
    private func place(_ shell: DockShellView, _ frame: DockPanelFrame?) {
        shell.isHidden = frame == nil
        guard let frame else {
            return
        }
        shell.alphaValue = CGFloat(frame.alpha)
        shell.frame = NSRect(
            x: 0,
            y: bounds.height - CGFloat(frame.offset) - CGFloat(frame.height),
            width: bounds.width,
            height: CGFloat(frame.height)
        )
    }
}

private extension DockPanelFrame {
    /// A panel at rest in its slot, fully shown; nil when it has none.
    init?(slot: DockColumnLayout.Slot?) {
        guard let slot else {
            return nil
        }
        self.init(offset: slot.offset, height: slot.height, alpha: 1)
    }
}
