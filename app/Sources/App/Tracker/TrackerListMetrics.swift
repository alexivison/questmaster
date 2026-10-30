import AppKit

enum TrackerListMetrics {
    /// The shell's own `G` (`ShellMetrics.gap`), applied leading-only (2026-10-07): the trailing
    /// edge is flush against the tracker frame's own trailing edge (and so the terminal pane),
    /// with Ghostty's own padding completing that gap instead of a second copy of this padding.
    static let sidePadding: CGFloat = ShellMetrics.gap
    /// 0, not a flat padding (2026-10-07): the tracker pane's own top edge already sits exactly
    /// `G` above the window's bottom reference, the same quantity that places the terminal's
    /// first row of text — see `ShellSplitLayoutPlanner`'s full-height tracker frame. The list's first plate starts from
    /// there, or a `spacing` lower when the header alignment (`TrackerHeaderAlignmentMetrics`) puts it higher, so its crown isn't cut.
    static let firstSectionTopInset: CGFloat = 0
    /// From the bottom of the plates to the selected-session panel's top edge. The plates' list stops this far above the
    /// panel, so the last plate's badge overhang clears it.
    static let selectedPanelGap = Space.group
    /// From the selected-session panel's bottom edge to the avatar slot's top.
    static let avatarGap = Space.section
    /// The bottom margin under the avatar slot, and under the shell section, which is pinned there.
    static let verticalPadding = Space.section
    /// Every gap in the list (2026-10-21): between project groups, between sessions, from a master to its workers and
    /// between workers, and after a session's workers. Each runs from the visible bottom of the item above (its disc, its
    /// collapsed workers' circles, or its open cast row) to the top of the next disc, and each row is exactly that tall,
    /// so the spacing is the gap.
    static let spacing = Space.item
    /// The widest tracker content: the selected-session panel and the master plate, both 260pt, and the plate band
    /// that reaches past their right edge, which the list's scroll view would otherwise clip. The tracker column is sized
    /// to it plus the leading `sidePadding`.
    static let contentWidth: CGFloat = SelectedSessionPanel.canvasSize.width + TrackerPlateDesign.glowBandWidth
}
