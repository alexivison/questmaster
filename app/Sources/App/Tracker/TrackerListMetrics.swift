import AppKit

enum TrackerListMetrics {
    /// The shell's own `G` (`ShellMetrics.gap`), applied leading-only (2026-10-07): the trailing
    /// edge is flush against the tracker frame's own trailing edge (and so the terminal pane),
    /// with Ghostty's own padding completing that gap instead of a second copy of this padding.
    static let sidePadding: CGFloat = ShellMetrics.gap
    /// The first plate's visible top is level with the action bar header's bottom edge. The tracker pane and the header
    /// both start `ShellMetrics.sideCardInset` below the window's top (`ShellSplitLayoutPlanner`), so the header's
    /// bottom is its height below the pane's top. The plate's row starts at its visible top (the silhouette margin is
    /// only in its layers), and no project header is drawn above it. The loading skeleton uses the same inset.
    static let firstSectionTopInset = ActionBarMetrics.height
    static let verticalPadding = Space.section
    /// The scrolling plates stop this far above the avatar's reserved slot. The avatar stands on the banner,
    /// followed by `Space.section` and the shells, or just the bottom `verticalPadding` when there are no shells.
    static let avatarClearance = Space.group
    /// The avatar stands this far above the session banner: the gap from the slot's bottom (the sole line, which every
    /// pose is measured from) to the banner's top. The slot keeps its size and the plate
    /// list above gives up the room. Review switch (2026-11-13, 0, 5 or 10 pt): the debug render preview sets the
    /// override; a release build is always `Space.item`.
    #if DEBUG
    nonisolated(unsafe) static var avatarBannerGapOverride: CGFloat?
    static var avatarBannerGap: CGFloat { avatarBannerGapOverride ?? Space.item }
    #else
    static let avatarBannerGap = Space.item
    #endif
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
