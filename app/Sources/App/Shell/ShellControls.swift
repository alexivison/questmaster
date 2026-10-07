import AppKit
import QuestmasterCore

/// Shared shell layout metrics and the selected-session chip value type. The
/// interactive AppKit controls that used to live here (segmented pills, icon
/// button, session chip view, status leaves) are now SwiftUI — see
/// `ShellChromeControls.swift`, `ShellTopBars.swift`, and `ShellStatusViews.swift`.

enum ShellMetrics {
    static let dockTopBarHeight: CGFloat = 40
    /// No extra space above the first tracker header (2026-10-07): `sideCardInset` alone now
    /// provides the window-top-to-tracker gap, matching every other G-rhythm gap in the shell.
    static let trackerTopInset: CGFloat = 0
    static let dockViewerLeadingLineExtension: CGFloat = 56
    static let sideCardTopBarHorizontalInset: CGFloat = 8
    static let sideCardOrnamentSide: CGFloat = 32
    static let sideCardOrnamentInset: CGFloat = 4
    static let dockTopBarLeadingInset: CGFloat = 18
    static let toastOrnamentSide: CGFloat = 16
    static let toastOrnamentInset: CGFloat = 3
    /// Bigger than `sideCardOrnamentInset` — the modal panel isn't a
    /// full-bleed side card, so its corners need more breathing room from
    /// the rounded edge. Deliberately not reused for `SideCardOrnaments`'
    /// own default so the tracker/dock inset stays untouched.
    static let modalOrnamentInset: CGFloat = 10
    /// The shell's own single gap `G` (2026-10-07) — applies to every pane-to-pane and
    /// pane-to-window-edge gap in the shell (tracker/dock side-card inset, tracker's own leading
    /// padding, the dock's and terminal's outer margins). A dedicated constant, not
    /// `Token.Spacing.element`: that token is used all over the rest of the app and stays 10:
    /// this is the shell's own rhythm, free to move independently (the user may bump it again
    /// after seeing 20).
    static let gap: CGFloat = 20
    static let sideCardInset = gap
    static let sideCardCornerRadius = Token.Radius.card
    /// Window edge to the tracker frame: 0, now that `TrackerListMetrics.sidePadding` (which
    /// tracks `gap`) alone, applied leading-only, provides the full gap to the plates.
    /// `trackerMaxWidth` grows to fit that same padding ahead of the plate's own fixed width, so
    /// it still lands flush against the terminal pane on its trailing edge, with only Ghostty's
    /// own padding completing that gap (2026-10-07).
    static let trackerLeadingInset: CGFloat = 0
    /// 0 whenever Ghostty's own padding already reaches `gap` on its own (true today: both
    /// horizontal and vertical Ghostty padding are 10, `gap` is 20, so both are 10) — otherwise
    /// the shortfall. Horizontal: tracker-to-terminal and terminal-to-dock (or window edge,
    /// dock hidden) — all the same axis, so the same value. Vertical: the terminal's own inset
    /// from the window's top edge.
    static let horizontalFlushGap = CGFloat(GhosttyGapDerivation.flushGap(g: Double(gap), ghosttyPadding: GhosttyWindowPadding.resolved.x))
    static let verticalFlushGap = CGFloat(GhosttyGapDerivation.flushGap(g: Double(gap), ghosttyPadding: GhosttyWindowPadding.resolved.y))
    static let trackerTrailingGap: CGFloat = horizontalFlushGap
    static let splitLayoutMetrics = ShellSplitLayoutMetrics(
        sideCardInset: Double(sideCardInset),
        dockDividerHitWidth: 7,
        trackerMaxWidth: Double(TrackerListMetrics.rootPlateWidth) + Double(gap),
        trackerLeadingInset: Double(trackerLeadingInset),
        trackerTrailingGap: Double(trackerTrailingGap),
        terminalToDockGap: Double(horizontalFlushGap),
        terminalTopInset: Double(verticalFlushGap),
        footerReservedHeight: Double(ActionBarMetrics.footerHeight)
    )
}

struct SelectedSessionChip: Equatable {
    let title: String
    let id: String
    let agent: String
}
