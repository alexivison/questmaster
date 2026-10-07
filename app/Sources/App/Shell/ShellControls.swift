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
    /// The single gap `G` (2026-10-07): applies to every pane-to-pane and pane-to-window-edge gap
    /// in the shell (tracker/dock side-card inset, tracker's own leading padding, the dock's outer
    /// margin). Was `Token.Spacing.card` (8); the user may bump this to `Token.Spacing.section`
    /// (20) after seeing it, so every gap below derives from this one constant.
    static let sideCardInset = Token.Spacing.element
    static let sideCardCornerRadius = Token.Radius.card
    /// Window edge to the tracker frame: 0, now that `TrackerListMetrics.sidePadding` alone
    /// (applied leading-only — see its own call sites) provides the full G gap to the plates.
    /// `trackerMaxWidth` shrinks by that same G below, so the plates still land flush against
    /// the terminal pane on their trailing edge, with only Ghostty's own padding completing that
    /// gap (2026-10-07).
    static let trackerLeadingInset: CGFloat = 0
    /// 0 whenever Ghostty's own horizontal padding already reaches G on its own (true today:
    /// both are 10) — otherwise the shortfall, on the same axis and so the same value, as
    /// `terminalToDockGap` below.
    static let horizontalFlushGap = CGFloat(GhosttyGapDerivation.flushGap(g: Double(Token.Spacing.element), ghosttyPadding: GhosttyWindowPadding.resolved.x))
    static let trackerTrailingGap: CGFloat = horizontalFlushGap
    static let splitLayoutMetrics = ShellSplitLayoutMetrics(
        sideCardInset: Double(sideCardInset),
        dockDividerHitWidth: 7,
        trackerMaxWidth: 300 - Double(Token.Spacing.element),
        trackerLeadingInset: Double(trackerLeadingInset),
        trackerTrailingGap: Double(trackerTrailingGap),
        terminalToDockGap: Double(horizontalFlushGap),
        footerReservedHeight: Double(ActionBarMetrics.footerHeight)
    )
}

struct SelectedSessionChip: Equatable {
    let title: String
    let id: String
    let agent: String
}
