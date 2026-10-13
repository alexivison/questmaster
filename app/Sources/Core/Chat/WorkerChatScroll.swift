import CoreGraphics

/// When the worker chat feed follows new lines: it does while its bottom edge is in view, and it
/// lets go the moment the user scrolls above that.
public enum WorkerChatScroll {
    public static let bottomTolerance: CGFloat = 2

    public static func isAtBottom(offset: CGFloat, viewportHeight: CGFloat, contentHeight: CGFloat) -> Bool {
        offset + viewportHeight >= contentHeight - bottomTolerance
    }

    /// The offset that shows the content's bottom edge, or nil while the content fits the viewport.
    public static func bottomOffset(viewportHeight: CGFloat, contentHeight: CGFloat) -> CGFloat? {
        contentHeight > viewportHeight ? contentHeight - viewportHeight : nil
    }

    /// How far the content glides after the clip jumps from `shownOffset` (where the content still
    /// appears) to `offset`. Capped at one viewport, so the rest of a long jump lands at once.
    public static func glideDistance(from shownOffset: CGFloat, to offset: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        min(max(offset - shownOffset, -viewportHeight), viewportHeight)
    }
}
