import AppKit

enum TrackerListMetrics {
    /// The shell's own `G` (`ShellMetrics.gap`), applied leading-only (2026-10-07): the trailing
    /// edge is flush against the tracker frame's own trailing edge (and so the terminal pane),
    /// with Ghostty's own padding completing that gap instead of a second copy of this padding.
    static let sidePadding: CGFloat = ShellMetrics.gap
    /// 0, not a flat padding (2026-10-07): the tracker pane's own top edge already sits exactly
    /// `G` above the window's bottom reference, the same quantity that places the terminal's
    /// first row of text — see `ShellSplitLayoutPlanner`'s full-height tracker frame. The selected
    /// session panel lands on that line; the list below it starts `selectedPanelGap` lower.
    static let firstSectionTopInset: CGFloat = 0
    /// From the selected-session panel's bottom edge (its 75pt canvas) to the first row's top, the first disc's top edge.
    /// The master's crown pieces reach 2pt above it, so they start 38pt below the panel.
    static let selectedPanelGap = Space.group
    static let verticalPadding = Space.section
    /// The shell section is pinned to the bottom of the tracker column, at `verticalPadding` from its edge, and the
    /// plates' list scrolls in the space above it. That space ends this far above the section, so the plates, however
    /// many, never come closer than `Space.group` to it (the badge's overhang past the last disc included: the list's own
    /// bottom padding holds it). With no shells the list has the column's full height.
    static let shellClearance = Space.group
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
