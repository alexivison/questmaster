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
    static let selectedPanelGap: CGFloat = 40
    static let verticalPadding: CGFloat = 20
    /// Between project groups, from the bottom of one group's last item to the top of the next group's first.
    static let sectionSpacing: CGFloat = 20
    /// Between top-level items. Every gap runs from the visible bottom of the item above, its disc or its chips'
    /// circles, to the top of the next disc, and each row is exactly that tall, so the spacing is the gap.
    static let itemSpacing: CGFloat = 20
    /// Between a master and its workers, and between the workers.
    static let masterBlockSpacing: CGFloat = 10
    /// The widest tracker content: the selected-session panel's 304pt design width, which the top-level
    /// plate (285pt) sits inside. The tracker column is sized to it plus the leading `sidePadding`.
    static let contentWidth: CGFloat = 304
}
