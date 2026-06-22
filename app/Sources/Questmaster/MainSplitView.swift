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
        firstDivider.isHidden = !trackerVisible
        secondDividerLine.isHidden = !dockVisible
        secondDividerGrab.isHidden = !dockVisible

        let visibleDividerCount: CGFloat = (trackerVisible ? 1 : 0) + (dockVisible ? 1 : 0)
        let availableWidth = max(0, bounds.width - (dividerWidth * visibleDividerCount))
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
        var x: CGFloat = 0
        panes[0].frame = NSRect(x: x, y: 0, width: trackerWidth, height: height)
        x += trackerWidth
        if trackerVisible {
            firstDivider.frame = NSRect(x: x, y: 0, width: dividerWidth, height: height)
            x += dividerWidth
        } else {
            firstDivider.frame = NSRect(x: 0, y: 0, width: 0, height: height)
        }
        panes[1].frame = NSRect(x: x, y: 0, width: terminalWidth, height: height)
        x += terminalWidth
        if dockVisible {
            secondDividerLine.frame = NSRect(x: x, y: 0, width: dividerWidth, height: height)
            secondDividerGrab.frame = NSRect(
                x: x - ((dockDividerHitWidth - dividerWidth) / 2),
                y: 0,
                width: dockDividerHitWidth,
                height: height
            )
            x += dividerWidth
            panes[2].frame = NSRect(x: x, y: 0, width: dockWidth, height: height)
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
        divider.layer?.backgroundColor = AppPalette.line.cgColor
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
        let visibleDividerCount: CGFloat = (trackerVisible ? 1 : 0) + 1
        let availableWidth = max(0, bounds.width - (dividerWidth * visibleDividerCount))
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
