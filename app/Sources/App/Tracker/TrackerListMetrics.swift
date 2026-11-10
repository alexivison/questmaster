import AppKit

enum TrackerListMetrics {
    /// The shell's own `G` (`ShellMetrics.gap`), applied leading-only (2026-10-07): the trailing
    /// edge is flush against the tracker frame's own trailing edge (and so the terminal pane),
    /// with Ghostty's own padding completing that gap instead of a second copy of this padding.
    static let sidePadding: CGFloat = ShellMetrics.gap
    /// 0, not a flat padding (2026-10-07): the tracker pane's own top edge already sits exactly
    /// `G` above the window's bottom reference, the same quantity that places the terminal's
    /// first row of text — see `ShellSplitLayoutPlanner`'s full-height tracker frame. The first
    /// plate section starts there, adjusted for the terminal's cell height when it is known.
    static let firstSectionTopInset: CGFloat = 0
    static let verticalPadding = Space.section
    /// The scrolling plates stop this far above the avatar's reserved slot. The avatar stands on the banner,
    /// followed by `Space.section` and the shells, or just the bottom `verticalPadding` when there are no shells.
    static let avatarClearance = Space.group
    /// Every gap in the list (2026-10-21): between project groups, between sessions, from a master to its workers and
    /// between workers, and after a session's workers. Each runs from the visible bottom of the item above (its disc, its
    /// collapsed workers' circles, or its open cast row) to the top of the next disc, and each row is exactly that tall,
    /// so the spacing is the gap.
    static let spacing = Space.item
    /// The widest tracker content: the session banner and the master plate, both 260pt, and the plate band
    /// that reaches past their right edge, which the list's scroll view would otherwise clip. The tracker column is sized
    /// to it plus the leading `sidePadding`.
    static let contentWidth: CGFloat = TrackerPlateDesign.topLevelSize.width + TrackerPlateDesign.glowBandWidth
}
