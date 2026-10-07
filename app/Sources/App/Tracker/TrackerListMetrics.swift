import AppKit

enum TrackerListMetrics {
    /// The shell's own `G` (`ShellMetrics.gap`), applied leading-only (2026-10-07): the trailing
    /// edge is flush against the tracker frame's own trailing edge (and so the terminal pane),
    /// with Ghostty's own padding completing that gap instead of a second copy of this padding.
    static let sidePadding: CGFloat = ShellMetrics.gap
    /// 0, not a flat padding (2026-10-07): the tracker pane's own top edge already sits exactly
    /// `G` above the window's bottom reference, the same quantity that places the terminal's
    /// first row of text — see `ShellSplitLayoutPlanner`'s full-height tracker frame. The first
    /// section's header needs no further push down to land on that same line; only later
    /// sections still want `sectionSpacing` between them.
    static let firstSectionTopInset: CGFloat = 0
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
