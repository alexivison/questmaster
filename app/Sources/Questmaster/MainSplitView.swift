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
    private let dockBorderHitWidth: CGFloat = 7
    private let firstDivider = NSView()
    private let secondDividerGrab = DockResizeDividerView()
    private var panes: [NSView] = []
    private var preferredDockWidth: CGFloat? = DockWidthPreference.storedWidth().map { CGFloat($0) }
    private var dockDragStartWidth: CGFloat = 0
    private var currentDockWidth: CGFloat = 0
    private var isAnimatingCanonicalLayout = false
    private var layoutAnimationGeneration = 0

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

    var dockVisible = false {
        didSet {
            guard dockVisible != oldValue else {
                return
            }
            applyCanonicalLayout(animated: true)
        }
    }

    var arrangedSubviews: [NSView] {
        panes
    }

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

    private func canonicalLayout() -> CanonicalLayout? {
        guard panes.count == 3, bounds.width > 0 else {
            return nil
        }
        let availableWidth = max(0, bounds.width - sideCardHorizontalInsets())
        let trackerWidth = trackerVisible ? min(300, availableWidth) : 0
        let proposedDockWidth = preferredDockWidth
            ?? CGFloat(DockWidthPreference.defaultWidth(forWindowWidth: Double(bounds.width)))
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
        panes[0].frame = layout.trackerFrame
        panes[1].frame = layout.terminalFrame
        panes[2].frame = layout.dockFrame
        firstDivider.frame = layout.firstDividerFrame
        secondDividerGrab.frame = layout.secondDividerFrame
        layoutPaneSubtrees()
    }

    private func animate(to layout: CanonicalLayout) {
        layoutAnimationGeneration += 1
        let generation = layoutAnimationGeneration
        let trackerWasHidden = panes[0].isHidden
        let dockWasHidden = panes[2].isHidden
        panes[0].isHidden = false
        panes[2].isHidden = false
        firstDivider.isHidden = true
        secondDividerGrab.isHidden = false
        if trackerVisible, trackerWasHidden {
            panes[0].alphaValue = 0
        }
        if dockVisible, dockWasHidden {
            panes[2].alphaValue = 0
            secondDividerGrab.alphaValue = 0
        }
        isAnimatingCanonicalLayout = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panes[0].animator().frame = layout.trackerFrame
            panes[0].animator().alphaValue = trackerVisible ? 1 : 0
            panes[1].animator().frame = layout.terminalFrame
            panes[2].animator().frame = layout.dockFrame
            panes[2].animator().alphaValue = dockVisible ? 1 : 0
            secondDividerGrab.animator().frame = layout.secondDividerFrame
            secondDividerGrab.animator().alphaValue = dockVisible ? 1 : 0
        } completionHandler: { [weak self] in
            guard let self, self.layoutAnimationGeneration == generation else {
                return
            }
            self.isAnimatingCanonicalLayout = false
            self.apply(layout)
        }
    }

    private func layoutPaneSubtrees() {
        for view in panes {
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
        }
    }

    override func layout() {
        super.layout()
        guard !isAnimatingCanonicalLayout else {
            return
        }
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

    private func beginDockResize() {
        guard dockVisible else {
            return
        }
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
        DockWidthPreference.store(width: Double(currentDockWidth))
    }
}
