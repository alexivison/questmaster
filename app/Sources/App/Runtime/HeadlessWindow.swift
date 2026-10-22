import AppKit

#if DEBUG
/// Dev-only: the window every self-test and render draws in. Borderless and far off-screen, and never
/// constrained back onto a screen, so nothing shows up on the user's display; it can still become key, so
/// first-responder and key-event tests work. `--run-logic-tests` and the render modes also run with the
/// `.prohibited` activation policy (QuestmasterMain), so they get no Dock icon and never take focus.
final class HeadlessWindow: NSWindow {
    private static let origin = CGPoint(x: -20000, y: -20000)

    /// The backing scale renders rasterize at; nil uses the screen's.
    private let renderScale: CGFloat?

    init(size: CGSize, scale: CGFloat? = nil) {
        renderScale = scale
        super.init(contentRect: NSRect(origin: Self.origin, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        hasShadow = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    /// Off every screen the window would have none, and screen-driven work (a scroll view's wheel scrolling)
    /// wouldn't run; it behaves as if on the main display.
    override var screen: NSScreen? { NSScreen.main }
    override var backingScaleFactor: CGFloat { renderScale ?? super.backingScaleFactor }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// Orders the window in, off-screen, so it lays out and draws; `key` also makes it the key window.
    func show(key: Bool = false) {
        orderFrontRegardless()
        if key {
            makeKey()
        }
    }
}
#endif
