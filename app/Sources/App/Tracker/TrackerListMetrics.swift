import AppKit

enum TrackerListMetrics {
    /// Applied leading-only (2026-10-07): the trailing edge is flush against the tracker frame's
    /// own trailing edge (and so the terminal pane), with Ghostty's own padding completing that
    /// gap instead of a second copy of this padding.
    static let sidePadding: CGFloat = 10
    static let verticalPadding: CGFloat = 20
    static let sectionSpacing: CGFloat = 30
    static let itemSpacing: CGFloat = 10
    static let masterBlockSpacing: CGFloat = 5
    static let workerIndent: CGFloat = 23
    static let rootPlateWidth: CGFloat = 280
    static let workerPlateWidth: CGFloat = 257
    static let standaloneCapHeight: CGFloat = 58
    static let masterCapHeight: CGFloat = 64
    static let masterCapWidth: CGFloat = 64
    static let workerCapHeight: CGFloat = 47
}
