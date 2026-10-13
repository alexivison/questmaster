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
    static let sectionSpacing: CGFloat = 30
    static let itemSpacing: CGFloat = 20
    static let masterBlockSpacing: CGFloat = 5
    /// The widest tracker content: the selected-session panel's 303pt design width, which the top-level
    /// plate (283pt) sits inside. The tracker column is sized to it plus the leading `sidePadding`.
    static let contentWidth: CGFloat = 303
}
