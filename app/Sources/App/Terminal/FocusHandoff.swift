import AppKit
import Foundation
import QuestmasterCore

func viewOwnsKeyFocus(_ view: NSView) -> Bool {
    guard let responder = view.window?.firstResponder else {
        return false
    }
    if responder === view {
        return true
    }
    return (responder as? NSView)?.isDescendant(of: view) == true
}

func focusDirection(from event: NSEvent, includeHorizontal: Bool = true) -> NavigationDirection? {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard flags.contains(.control),
          !flags.contains(.command),
          !flags.contains(.option) else {
        return nil
    }
    guard let direction = Keymap.ControlHandoff.direction(forKeyCode: event.keyCode) else {
        return nil
    }
    switch direction {
    case .left, .right:
        return includeHorizontal ? direction : nil
    case .up, .down:
        return direction
    }
}

final class KeyHandlingTextView: NSTextView {
    var onControlDirection: ((NavigationDirection) -> Bool)?
    var onBareKey: ((String, NSEvent) -> Bool)?
    var onCharacterClick: ((Int) -> Bool)?
    var suppressesScrollRangeToVisible = false
    var usesStableArrowCursor = false {
        didSet {
            refreshStableArrowCursor()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshStableArrowCursor()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refreshStableArrowCursor()
    }

    func refreshStableArrowCursor() {
        guard usesStableArrowCursor else {
            return
        }
        window?.invalidateCursorRects(for: self)
        guard let window else {
            return
        }
        let windowPoint = window.mouseLocationOutsideOfEventStream
        if bounds.contains(convert(windowPoint, from: nil)) {
            NSCursor.arrow.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        if let characterIndex = characterIndex(for: event),
           onCharacterClick?(characterIndex) == true {
            return
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if let direction = focusDirection(from: event, includeHorizontal: false),
           onControlDirection?(direction) == true {
            return
        }
        if let direction = focusDirection(from: event, includeHorizontal: false) {
            switch direction {
            case .up:
                scrollBy(lines: -3)
                return
            case .down:
                scrollBy(lines: 3)
                return
            case .left, .right:
                return
            }
        }
        if isNativeRegionTabEvent(event) {
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.subtracting(.shift).isEmpty,
           let key = rawViewerKey(for: event, flags: flags),
           onBareKey?(key, event) == true {
            return
        }
        if scrollReadSurface(with: event) {
            return
        }
        super.keyDown(with: event)
    }

    override func resetCursorRects() {
        guard usesStableArrowCursor else {
            super.resetCursorRects()
            return
        }
        addCursorRect(bounds, cursor: .arrow)
    }

    override func cursorUpdate(with event: NSEvent) {
        guard usesStableArrowCursor else {
            super.cursorUpdate(with: event)
            return
        }
        NSCursor.arrow.set()
    }

    override func mouseEntered(with event: NSEvent) {
        guard usesStableArrowCursor else {
            super.mouseEntered(with: event)
            return
        }
        NSCursor.arrow.set()
    }

    override func mouseMoved(with event: NSEvent) {
        guard usesStableArrowCursor else {
            super.mouseMoved(with: event)
            return
        }
        NSCursor.arrow.set()
    }

    override func insertTab(_ sender: Any?) {}

    override func insertBacktab(_ sender: Any?) {}

    override func scrollRangeToVisible(_ range: NSRange) {
        guard !suppressesScrollRangeToVisible else {
            return
        }
        super.scrollRangeToVisible(range)
    }

    private func scrollReadSurface(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(.control), !flags.contains(.command), !flags.contains(.option), !flags.contains(.shift) else {
            return false
        }

        if Keymap.ReadSurfaceScroll.lineUpKeyCodes.matches(event.keyCode) {
            scrollBy(lines: -3)
            return true
        }
        if Keymap.ReadSurfaceScroll.lineDownKeyCodes.matches(event.keyCode) {
            scrollBy(lines: 3)
            return true
        }
        if Keymap.ReadSurfaceScroll.pageUp.matches(event.keyCode) {
            scrollByPages(-1)
            return true
        }
        if Keymap.ReadSurfaceScroll.pageDown.matches(event.keyCode) {
            scrollByPages(1)
            return true
        }

        let key = event.charactersIgnoringModifiers?.lowercased()
        if Keymap.ReadSurfaceScroll.lineUpCharacter.matches(key) {
            scrollBy(lines: -3)
            return true
        }
        if Keymap.ReadSurfaceScroll.lineDownCharacter.matches(key) {
            scrollBy(lines: 3)
            return true
        }
        return false
    }

    private func scrollBy(lines: CGFloat) {
        scrollBy(points: lines * 18)
    }

    private func scrollByPages(_ pages: CGFloat) {
        let height = enclosingScrollView?.contentView.bounds.height ?? 240
        scrollBy(points: pages * max(60, height * 0.82))
    }

    private func scrollBy(points: CGFloat) {
        guard let scrollView = enclosingScrollView else {
            return
        }
        let clipView = scrollView.contentView
        let maxY = max(0, bounds.height - clipView.bounds.height)
        let nextY = min(max(0, clipView.bounds.origin.y + points), maxY)
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: nextY))
        scrollView.reflectScrolledClipView(clipView)
    }

    private func rawViewerKey(for event: NSEvent, flags: NSEvent.ModifierFlags) -> String? {
        if Keymap.Viewer.moveUpKeyCodes.matches(event.keyCode) {
            return "up"
        }
        if Keymap.Viewer.moveDownKeyCodes.matches(event.keyCode) {
            return "down"
        }
        if Keymap.Viewer.backKeyCodes.matches(event.keyCode) {
            return "left"
        }
        if Keymap.Viewer.pageUp.matches(event.keyCode) {
            return "page-up"
        }
        if Keymap.Viewer.pageDown.matches(event.keyCode) {
            return "page-down"
        }
        if flags.contains(.shift) {
            return event.characters
        }
        return event.charactersIgnoringModifiers?.lowercased()
    }

    private func characterIndex(for event: NSEvent) -> Int? {
        guard let layoutManager,
              let textContainer,
              !string.isEmpty else {
            return nil
        }

        var point = convert(event.locationInWindow, from: nil)
        point.x -= textContainerOrigin.x
        point.y -= textContainerOrigin.y
        guard point.x >= 0, point.y >= 0 else {
            return nil
        }

        layoutManager.ensureLayout(for: textContainer)
        let glyphIndex = layoutManager.glyphIndex(for: point, in: textContainer)
        guard glyphIndex < layoutManager.numberOfGlyphs else {
            return nil
        }

        let lineRect = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        guard lineRect.insetBy(dx: -6, dy: -3).contains(point) else {
            return nil
        }

        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        let length = (string as NSString).length
        return characterIndex < length ? characterIndex : nil
    }
}

func isNativeRegionTabEvent(_ event: NSEvent) -> Bool {
    guard Keymap.NativeRegion.tabNoOp.matches(event.keyCode) else {
        return false
    }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let disallowed: NSEvent.ModifierFlags = [.command, .control, .option]
    return flags.intersection(disallowed).isEmpty && flags.subtracting(.shift).isEmpty
}

