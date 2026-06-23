import AppKit
import QuestmasterCore

final class NativeTextSurface: NSView {
    private let scrollView = NSScrollView()
    private let textView = KeyHandlingTextView()
    private var inlineView: NSView?
    private var inlineViewRange: NSRange?
    private var inlineViewHeight: CGFloat = 0
    private var focusClickMonitor: Any?
    var onFocusRequested: (() -> Void)?
    var onOpenLink: ((URL) -> Bool)?
    var onControlDirection: ((NavigationDirection) -> Bool)? {
        didSet {
            textView.onControlDirection = onControlDirection
        }
    }
    var onBareKey: ((String, NSEvent) -> Bool)? {
        didSet {
            textView.onBareKey = onBareKey
        }
    }
    var onCharacterClick: ((Int) -> Bool)? {
        didSet {
            textView.onCharacterClick = onCharacterClick
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = AppPalette.questViewerBackground.cgColor

        textView.isEditable = false
        textView.isSelectable = true
        textView.usesStableArrowCursor = true
        textView.drawsBackground = true
        textView.backgroundColor = AppPalette.questViewerBackground
        textView.textColor = AppPalette.text
        textView.font = AppFonts.mono
        textView.textContainerInset = NSSize(width: 22, height: 20)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = self

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    deinit {
        removeFocusClickMonitor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateFocusClickMonitor()
    }

    override func layout() {
        super.layout()
        updateTextViewWidth()
        updateInlineViewFrame()
    }

    override func keyDown(with event: NSEvent) {
        if isNativeRegionTabEvent(event) {
            return
        }
        super.keyDown(with: event)
    }

    func setContent(_ content: NSAttributedString, preserveScroll: Bool = false) {
        let origin = scrollView.contentView.bounds.origin
        guard let textStorage = textView.textStorage else {
            return
        }
        if textStorage.isEqual(to: content) {
            updateInlineViewFrame()
            return
        }
        textView.suppressesScrollRangeToVisible = preserveScroll
        updateTextViewWidth()
        textStorage.beginEditing()
        textStorage.replaceCharacters(
            in: NSRange(location: 0, length: textStorage.length),
            with: content
        )
        textStorage.endEditing()
        updateTextViewWidth()
        if preserveScroll {
            restoreScrollOrigin(origin)
            DispatchQueue.main.async { [weak self] in
                self?.restoreScrollOrigin(origin)
                self?.textView.suppressesScrollRangeToVisible = false
            }
        } else {
            restoreScrollOrigin(.zero)
            textView.suppressesScrollRangeToVisible = false
        }
        updateInlineViewFrame()
    }

    func updateFocusHighlight(previousRange: NSRange?, focusedRange: NSRange?) {
        guard previousRange != focusedRange,
              let textStorage = textView.textStorage else {
            return
        }

        let origin = scrollView.contentView.bounds.origin
        textView.suppressesScrollRangeToVisible = true
        textStorage.beginEditing()
        if let previousRange = boundedRange(previousRange, in: textStorage) {
            textStorage.removeAttribute(.backgroundColor, range: previousRange)
        }
        if let focusedRange = boundedRange(focusedRange, in: textStorage) {
            textStorage.addAttribute(.backgroundColor, value: AppPalette.selection, range: focusedRange)
        }
        textStorage.endEditing()
        restoreScrollOrigin(origin)
        DispatchQueue.main.async { [weak self] in
            self?.restoreScrollOrigin(origin)
            self?.textView.suppressesScrollRangeToVisible = false
        }
        updateInlineViewFrame()
    }

    func scrollBy(lines: CGFloat) {
        scrollBy(points: lines * 18)
    }

    func scrollByPages(_ pages: CGFloat) {
        let height = scrollView.contentView.bounds.height
        scrollBy(points: pages * max(60, height * 0.82))
    }

    func scrollRangeToVisible(_ range: NSRange) {
        guard range.location != NSNotFound, range.length >= 0 else {
            return
        }
        let wasSuppressing = textView.suppressesScrollRangeToVisible
        textView.suppressesScrollRangeToVisible = false
        textView.scrollRangeToVisible(range)
        textView.suppressesScrollRangeToVisible = wasSuppressing
        updateInlineViewFrame()
    }

    func visibleCharacterRange() -> NSRange? {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return nil
        }
        updateTextViewWidth()
        layoutManager.ensureLayout(for: textContainer)
        var rect = scrollView.contentView.bounds
        let origin = textView.textContainerOrigin
        rect.origin.x -= origin.x
        rect.origin.y -= origin.y
        let glyphRange = layoutManager.glyphRange(forBoundingRect: rect, in: textContainer)
        return layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
    }

    func setInlineView(_ view: NSView?, range: NSRange?, height: CGFloat) {
        if inlineView !== view {
            inlineView?.removeFromSuperview()
        }
        inlineView = view
        inlineViewRange = range
        inlineViewHeight = height
        guard let view, range != nil else {
            view?.isHidden = true
            return
        }
        view.translatesAutoresizingMaskIntoConstraints = true
        if view.superview !== textView {
            view.removeFromSuperview()
            textView.addSubview(view)
        }
        view.isHidden = false
        updateInlineViewFrame()
    }

    func focus(in window: NSWindow?) {
        window?.makeFirstResponder(textView)
    }

    private func updateTextViewWidth() {
        let clipWidth = scrollView.contentView.bounds.width
        guard clipWidth > 0 else {
            return
        }
        textView.textContainer?.containerSize = NSSize(width: clipWidth, height: CGFloat.greatestFiniteMagnitude)
        textView.frame.size.width = clipWidth
        updateInlineViewFrame()
    }

    private func scrollBy(points: CGFloat) {
        let clipView = scrollView.contentView
        let maxY = max(0, textView.bounds.height - clipView.bounds.height)
        let nextY = min(max(0, clipView.bounds.origin.y + points), maxY)
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: nextY))
        scrollView.reflectScrolledClipView(clipView)
        updateInlineViewFrame()
    }

    private func restoreScrollOrigin(_ origin: NSPoint) {
        let clipView = scrollView.contentView
        let maxX = max(0, textView.bounds.width - clipView.bounds.width)
        let maxY = max(0, textView.bounds.height - clipView.bounds.height)
        clipView.scroll(to: NSPoint(
            x: min(max(0, origin.x), maxX),
            y: min(max(0, origin.y), maxY)
        ))
        scrollView.reflectScrolledClipView(clipView)
        updateInlineViewFrame()
    }

    private func boundedRange(_ range: NSRange?, in textStorage: NSTextStorage) -> NSRange? {
        guard let range,
              range.location != NSNotFound,
              range.location >= 0,
              range.length > 0,
              range.location < textStorage.length else {
            return nil
        }
        return NSRange(location: range.location, length: min(range.length, textStorage.length - range.location))
    }

    private func updateFocusClickMonitor() {
        removeFocusClickMonitor()
        guard window != nil else {
            return
        }
        focusClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            self?.requestFocusIfClickIsInside(event)
            return event
        }
    }

    private func removeFocusClickMonitor() {
        if let focusClickMonitor {
            NSEvent.removeMonitor(focusClickMonitor)
            self.focusClickMonitor = nil
        }
    }

    private func requestFocusIfClickIsInside(_ event: NSEvent) {
        guard !isHidden,
              let window,
              event.window === window,
              bounds.contains(convert(event.locationInWindow, from: nil)) else {
            return
        }
        onFocusRequested?()
    }

    private func updateInlineViewFrame() {
        guard let view = inlineView,
              let range = inlineViewRange,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let textStorage = textView.textStorage,
              textStorage.length > 0,
              range.location >= 0,
              range.location < textStorage.length else {
            inlineView?.isHidden = true
            return
        }
        layoutManager.ensureLayout(for: textContainer)
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: range.location)
        let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        let origin = textView.textContainerOrigin
        let inset = max(8, textView.textContainerInset.width)
        let width = max(120, textView.bounds.width - (inset * 2))
        view.frame = NSRect(
            x: inset,
            y: origin.y + lineRect.minY,
            width: width,
            height: inlineViewHeight
        )
        view.isHidden = false
    }
}

extension NativeTextSurface: NSTextViewDelegate {
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let url = link as? URL {
            return onOpenLink?(url) ?? false
        }
        if let raw = link as? String, let url = URL(string: raw) {
            return onOpenLink?(url) ?? false
        }
        return false
    }
}
