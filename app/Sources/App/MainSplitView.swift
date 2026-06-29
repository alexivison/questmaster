import AppKit
import QuestmasterCore

enum RightDockWidthMode {
    case standard
    case compact
}

private final class DockResizeDividerView: NSView {
    var onDragBegan: (() -> Void)?
    var onDragDelta: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?

    private var dragStartX: CGFloat?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        dragStartX = xInSuperview(for: event)
        onDragBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartX,
              let currentX = xInSuperview(for: event) else {
            return
        }
        onDragDelta?(currentX - dragStartX)
    }

    override func mouseUp(with event: NSEvent) {
        dragStartX = nil
        onDragEnded?()
    }

    private func xInSuperview(for event: NSEvent) -> CGFloat? {
        superview?.convert(event.locationInWindow, from: nil).x
    }
}

final class MainSplitView: NSView {
    private let dockBorderHitWidth: CGFloat = 7
    private let firstDivider = NSView()
    private let secondDividerGrab = DockResizeDividerView()
    private var panes: [NSView] = []
    private let defaultPreferredDockWidth: CGFloat? = DockWidthPreference.storedWidth().map { CGFloat($0) }
    private var preferredDockWidth: CGFloat? = DockWidthPreference.storedWidth().map { CGFloat($0) }
    private var dockWidthMode: RightDockWidthMode = .standard
    private var dockDragStartWidth: CGFloat = 0
    private var currentDockWidth: CGFloat = 0
    private var isAnimatingCanonicalLayout = false
    private var layoutAnimationGeneration = 0
    var onDockWidthCommitted: ((Double) -> Void)?

    private enum CanonicalAnimation {
        static let duration: TimeInterval = 0.18
        static let timingFunction = CAMediaTimingFunction(name: .easeOut)
    }

    private struct CanonicalLayout {
        let trackerFrame: NSRect
        let terminalFrame: NSRect
        let dockFrame: NSRect
        let firstDividerFrame: NSRect
        let secondDividerFrame: NSRect
        let dockWidth: CGFloat
    }

    var trackerVisible = true {
        didSet {
            guard trackerVisible != oldValue else {
                return
            }
            applyCanonicalLayout(animated: true)
        }
    }

    private(set) var dockVisible = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = AppPalette.window.cgColor
        configure(divider: firstDivider)
        secondDividerGrab.onDragBegan = { [weak self] in
            self?.beginDockResize()
        }
        secondDividerGrab.onDragDelta = { [weak self] deltaX in
            self?.resizeDock(deltaX: deltaX)
        }
        secondDividerGrab.onDragEnded = { [weak self] in
            self?.commitDockResize()
        }
        addSubview(firstDivider)
        addSubview(secondDividerGrab)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func addArrangedSubview(_ view: NSView) {
        panes.append(view)
        addSubview(view, positioned: .below, relativeTo: nil)
        needsLayout = true
    }

    func applyCanonicalLayout(animated: Bool = false) {
        guard let layout = canonicalLayout() else {
            return
        }
        currentDockWidth = layout.dockWidth
        if animated, window != nil {
            animate(to: layout)
        } else {
            apply(layout)
        }
    }

    func layoutCanonicalFramesIfIdle() {
        guard !isAnimatingCanonicalLayout else {
            return
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func setDockVisible(_ visible: Bool, animated: Bool = true) {
        guard dockVisible != visible else {
            return
        }
        dockVisible = visible
        applyCanonicalLayout(animated: animated)
    }

    func setDockPreferredWidth(_ width: Double?, animated: Bool = false) {
        let nextWidth = width.map { CGFloat($0) } ?? defaultPreferredDockWidth
        guard preferredDockWidth != nextWidth else {
            return
        }
        preferredDockWidth = nextWidth
        if dockWidthMode == .standard {
            applyCanonicalLayout(animated: animated)
        }
    }

    func setDockWidthMode(_ mode: RightDockWidthMode, animated: Bool = true) {
        guard dockWidthMode != mode else {
            return
        }
        dockWidthMode = mode
        applyCanonicalLayout(animated: animated)
    }

    private func canonicalLayout() -> CanonicalLayout? {
        guard panes.count == 3, bounds.width > 0 else {
            return nil
        }
        let availableWidth = max(0, bounds.width - sideCardHorizontalInsets())
        let trackerWidth = trackerVisible ? min(300, availableWidth) : 0
        let proposedDockWidth = proposedDockWidth(forWindowWidth: bounds.width)
        let dockWidth = dockVisible
            ? CGFloat(DockWidthPreference.clampedWidth(
                Double(proposedDockWidth),
                availableWidth: Double(availableWidth),
                trackerWidth: Double(trackerWidth)
            ))
            : 0
        let terminalWidth = max(0, availableWidth - trackerWidth - dockWidth)

        let height = bounds.height
        let sideCardY = ShellMetrics.sideCardInset
        let sideCardHeight = max(0, height - (ShellMetrics.sideCardInset * 2))
        var x: CGFloat = 0
        let trackerFrame: NSRect
        let firstDividerFrame: NSRect
        if trackerVisible {
            trackerFrame = NSRect(
                x: ShellMetrics.sideCardInset,
                y: sideCardY,
                width: trackerWidth,
                height: sideCardHeight
            )
            x = trackerFrame.maxX + ShellMetrics.sideCardInset
            firstDividerFrame = NSRect(x: trackerFrame.maxX, y: sideCardY, width: 0, height: sideCardHeight)
        } else {
            trackerFrame = NSRect(x: 0, y: sideCardY, width: 0, height: sideCardHeight)
            firstDividerFrame = NSRect(x: 0, y: 0, width: 0, height: 0)
        }
        let terminalFrame = NSRect(x: x, y: 0, width: terminalWidth, height: height)
        x += terminalWidth
        let secondDividerFrame: NSRect
        let dockFrame: NSRect
        if dockVisible {
            let dockGapX = x
            let dockCardMinX = dockGapX + ShellMetrics.sideCardInset
            secondDividerFrame = NSRect(
                x: dockCardMinX - (dockBorderHitWidth / 2),
                y: sideCardY,
                width: dockBorderHitWidth,
                height: sideCardHeight
            )
            dockFrame = NSRect(
                x: dockCardMinX,
                y: sideCardY,
                width: dockWidth,
                height: sideCardHeight
            )
        } else {
            secondDividerFrame = NSRect(x: bounds.width, y: sideCardY, width: 0, height: sideCardHeight)
            dockFrame = NSRect(x: bounds.width, y: sideCardY, width: 0, height: sideCardHeight)
        }

        return CanonicalLayout(
            trackerFrame: trackerFrame,
            terminalFrame: terminalFrame,
            dockFrame: dockFrame,
            firstDividerFrame: firstDividerFrame,
            secondDividerFrame: secondDividerFrame,
            dockWidth: dockWidth
        )
    }

    private func apply(_ layout: CanonicalLayout) {
        layoutAnimationGeneration += 1
        isAnimatingCanonicalLayout = false
        panes[0].isHidden = !trackerVisible
        panes[2].isHidden = !dockVisible
        firstDivider.isHidden = true
        secondDividerGrab.isHidden = !dockVisible
        panes[0].alphaValue = trackerVisible ? 1 : 0
        panes[2].alphaValue = dockVisible ? 1 : 0
        secondDividerGrab.alphaValue = dockVisible ? 1 : 0
        firstDivider.frame = layout.firstDividerFrame
        secondDividerGrab.frame = layout.secondDividerFrame
        setPaneFrame(panes[0], layout.trackerFrame)
        setPaneFrame(panes[1], layout.terminalFrame)
        setPaneFrame(panes[2], layout.dockFrame)
    }

    private func animate(to layout: CanonicalLayout) {
        layoutAnimationGeneration += 1
        let generation = layoutAnimationGeneration
        let trackerWasHidden = panes[0].isHidden
        let dockWasHidden = panes[2].isHidden
        prepareAnimatedPane(panes[0], isVisible: trackerVisible, wasHidden: trackerWasHidden)
        prepareAnimatedPane(panes[2], isVisible: dockVisible, wasHidden: dockWasHidden)
        firstDivider.isHidden = true
        let dockDividerParticipates = dockVisible || !dockWasHidden
        secondDividerGrab.isHidden = !dockDividerParticipates
        if dockVisible, dockWasHidden {
            secondDividerGrab.alphaValue = 0
        }
        isAnimatingCanonicalLayout = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = CanonicalAnimation.duration
            context.timingFunction = CanonicalAnimation.timingFunction
            animatePane(panes[0], to: layout.trackerFrame, isVisible: trackerVisible)
            panes[1].animator().frame = layout.terminalFrame
            animatePane(panes[2], to: layout.dockFrame, isVisible: dockVisible)
            if dockDividerParticipates {
                secondDividerGrab.animator().frame = layout.secondDividerFrame
                secondDividerGrab.animator().alphaValue = dockVisible ? 1 : 0
            }
        } completionHandler: { [weak self] in
            guard let self, self.layoutAnimationGeneration == generation else {
                return
            }
            self.isAnimatingCanonicalLayout = false
            self.apply(layout)
        }
    }

    private func prepareAnimatedPane(_ pane: NSView, isVisible: Bool, wasHidden: Bool) {
        guard isVisible || !wasHidden else {
            return
        }
        pane.isHidden = false
        if isVisible, wasHidden {
            pane.alphaValue = 0
        }
    }

    private func animatePane(_ pane: NSView, to frame: NSRect, isVisible: Bool) {
        pane.animator().frame = frame
        pane.animator().alphaValue = isVisible ? 1 : 0
    }

    /// Sets a pane's frame and re-lays out its subtree only when the frame
    /// actually changed. Skipping unchanged panes avoids a spurious terminal
    /// resize (and tmux pane reflow) on session switches, which force a
    /// canonical relayout without changing any geometry. Genuine geometry
    /// changes (window resize, tracker/dock toggle) still resize normally.
    private func setPaneFrame(_ pane: NSView, _ frame: NSRect) {
        let changed = pane.frame != frame
        pane.frame = frame
        guard changed else {
            return
        }
        pane.needsLayout = true
        pane.layoutSubtreeIfNeeded()
    }

    override func layout() {
        guard !isAnimatingCanonicalLayout else {
            return
        }
        super.layout()
        applyCanonicalLayout()
    }

    private func configure(divider: NSView) {
        divider.wantsLayer = true
        divider.layer?.backgroundColor = AppPalette.lineSoftSubtle.cgColor
    }

    private func sideCardHorizontalInsets() -> CGFloat {
        let trackerInsets = trackerVisible ? ShellMetrics.sideCardInset * 2 : 0
        let dockInsets = dockVisible ? ShellMetrics.sideCardInset * 2 : 0
        return trackerInsets + dockInsets
    }

    private func proposedDockWidth(forWindowWidth windowWidth: CGFloat) -> CGFloat {
        switch dockWidthMode {
        case .standard:
            return preferredDockWidth
                ?? CGFloat(DockWidthPreference.defaultWidth(forWindowWidth: Double(windowWidth)))
        case .compact:
            return CGFloat(DockWidthPreference.compactWidth)
        }
    }

    private func beginDockResize() {
        guard dockVisible else {
            return
        }
        dockWidthMode = .standard
        dockDragStartWidth = currentDockWidth
    }

    private func resizeDock(deltaX: CGFloat) {
        guard dockVisible else {
            return
        }
        let availableWidth = max(0, bounds.width - sideCardHorizontalInsets())
        let trackerWidth = trackerVisible ? min(300, availableWidth) : 0
        let proposedWidth = dockDragStartWidth - deltaX
        let width = CGFloat(DockWidthPreference.clampedWidth(
            Double(proposedWidth),
            availableWidth: Double(availableWidth),
            trackerWidth: Double(trackerWidth)
        ))
        preferredDockWidth = width
        applyCanonicalLayout()
    }

    private func commitDockResize() {
        guard dockVisible else {
            return
        }
        onDockWidthCommitted?(Double(currentDockWidth))
    }
}
