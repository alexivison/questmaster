import AppKit
import QuestmasterCore

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

    /// Both side cards must render above the terminal, or the terminal's frame
    /// growing into a closing card's space visually covers the card's own
    /// close animation mid-flight (only the tracker happened to end up above
    /// the terminal from insertion order; the dock did not).
    func sendTerminalToBack() {
        guard panes.count == 3 else {
            return
        }
        addSubview(panes[1], positioned: .below, relativeTo: nil)
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

    func nudgeDockWidth(by step: Double) {
        guard dockVisible, dockWidthMode == .standard else {
            return
        }
        preferredDockWidth = CGFloat(ShellSplitLayoutPlanner.resizedDockWidth(
            startWidth: Double(currentDockWidth),
            deltaX: -step,
            windowWidth: Double(bounds.width),
            metrics: ShellMetrics.splitLayoutMetrics,
            trackerVisible: trackerVisible,
            dockVisible: dockVisible
        ))
        applyCanonicalLayout(animated: true)
        onDockWidthCommitted?(Double(currentDockWidth))
    }

    func setDockWidthMode(_ mode: RightDockWidthMode, animated: Bool = true) {
        guard dockWidthMode != mode else {
            return
        }
        dockWidthMode = mode
        applyCanonicalLayout(animated: animated)
    }

    private func canonicalLayout() -> CanonicalLayout? {
        guard panes.count == 3,
              let layout = ShellSplitLayoutPlanner.layout(
                size: ShellSplitSize(width: Double(bounds.width), height: Double(bounds.height)),
                metrics: ShellMetrics.splitLayoutMetrics,
                trackerVisible: trackerVisible,
                dockVisible: dockVisible,
                preferredDockWidth: preferredDockWidth.map(Double.init),
                dockWidthMode: dockWidthMode
              ) else {
            return nil
        }

        return CanonicalLayout(
            trackerFrame: nsRect(layout.trackerFrame),
            terminalFrame: nsRect(layout.terminalFrame),
            dockFrame: nsRect(layout.dockFrame),
            firstDividerFrame: nsRect(layout.firstDividerFrame),
            secondDividerFrame: nsRect(layout.secondDividerFrame),
            dockWidth: CGFloat(layout.dockWidth)
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

    private func nsRect(_ rect: ShellSplitRect) -> NSRect {
        NSRect(
            x: CGFloat(rect.x),
            y: CGFloat(rect.y),
            width: CGFloat(rect.width),
            height: CGFloat(rect.height)
        )
    }

    #if DEBUG
    func debugPaneFrames() -> [NSRect] {
        panes.map(\.frame)
    }
    #endif

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

    private func beginDockResize() {
        guard dockVisible, dockWidthMode == .standard else {
            return
        }
        dockDragStartWidth = currentDockWidth
    }

    private func resizeDock(deltaX: CGFloat) {
        guard dockVisible, dockWidthMode == .standard else {
            return
        }
        preferredDockWidth = CGFloat(ShellSplitLayoutPlanner.resizedDockWidth(
            startWidth: Double(dockDragStartWidth),
            deltaX: Double(deltaX),
            windowWidth: Double(bounds.width),
            metrics: ShellMetrics.splitLayoutMetrics,
            trackerVisible: trackerVisible,
            dockVisible: dockVisible
        ))
        applyCanonicalLayout()
    }

    private func commitDockResize() {
        guard dockVisible, dockWidthMode == .standard else {
            return
        }
        onDockWidthCommitted?(Double(currentDockWidth))
    }
}
