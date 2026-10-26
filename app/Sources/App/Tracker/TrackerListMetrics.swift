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
    /// From the last plate's row (its disc's bottom edge) to the first shell row, under every master and worker. The
    /// tracker mock measures 45 there (53px at its 1.177 px/pt); that is `Space.group` clear of the agent badge, which
    /// hangs `badgeInset` below the disc. Without a plate, the section starts like the first plate: `selectedPanelGap`.
    static let shellSectionGap = Space.group + TrackerPlateDesign.badgeInset
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
