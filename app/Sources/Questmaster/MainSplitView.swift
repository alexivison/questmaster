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
    private let dividerWidth: CGFloat = 1
    private let dockDividerHitWidth: CGFloat = 7
    private let firstDivider = NSView()
    private let secondDividerLine = NSView()
    private let secondDividerGrab = DockResizeDividerView()
    private var panes: [NSView] = []
    private var preferredDockWidth: CGFloat? = DockWidthPreference.storedWidth().map { CGFloat($0) }
    private var dockDragStartWidth: CGFloat = 0
    private var currentDockWidth: CGFloat = 0

    var trackerVisible = true {
        didSet {
            applyCanonicalLayout()
        }
    }

    var dockVisible = false {
        didSet {
            applyCanonicalLayout()
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
        configure(divider: secondDividerLine)
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
        addSubview(secondDividerLine)
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

    func applyCanonicalLayout() {
        guard panes.count == 3, bounds.width > 0 else {
            return
        }

        panes[0].isHidden = !trackerVisible
        panes[2].isHidden = !dockVisible
        firstDivider.isHidden = true
        secondDividerLine.isHidden = !dockVisible
        secondDividerGrab.isHidden = !dockVisible

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
        currentDockWidth = dockWidth
        let terminalWidth = max(0, availableWidth - trackerWidth - dockWidth)

        let height = bounds.height
        let sideCardY = ShellMetrics.sideCardInset
        let sideCardHeight = max(0, height - (ShellMetrics.sideCardInset * 2))
        var x: CGFloat = 0
        if trackerVisible {
            panes[0].frame = NSRect(
                x: ShellMetrics.sideCardInset,
                y: sideCardY,
                width: trackerWidth,
                height: sideCardHeight
            )
            x = panes[0].frame.maxX + ShellMetrics.sideCardInset
            firstDivider.frame = NSRect(x: panes[0].frame.maxX, y: sideCardY, width: 0, height: sideCardHeight)
        } else {
            panes[0].frame = NSRect(x: 0, y: 0, width: 0, height: 0)
            firstDivider.frame = NSRect(x: 0, y: 0, width: 0, height: 0)
        }
        panes[1].frame = NSRect(x: x, y: 0, width: terminalWidth, height: height)
        x += terminalWidth
        if dockVisible {
            let dockGapX = x
            secondDividerLine.frame = NSRect(
                x: dockGapX + ((ShellMetrics.sideCardInset - dividerWidth) / 2),
                y: sideCardY,
                width: dividerWidth,
                height: sideCardHeight
            )
            secondDividerGrab.frame = NSRect(
                x: dockGapX + ((ShellMetrics.sideCardInset - dockDividerHitWidth) / 2),
                y: 0,
                width: dockDividerHitWidth,
                height: height
            )
            panes[2].frame = NSRect(
                x: dockGapX + ShellMetrics.sideCardInset,
                y: sideCardY,
                width: dockWidth,
                height: sideCardHeight
            )
        } else {
            secondDividerLine.frame = NSRect(x: bounds.width, y: 0, width: 0, height: height)
            secondDividerGrab.frame = NSRect(x: bounds.width, y: 0, width: 0, height: height)
            panes[2].frame = NSRect(x: bounds.width, y: 0, width: 0, height: height)
        }

        for view in panes {
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
        }
    }

    override func layout() {
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
