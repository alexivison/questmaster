import AppKit
import QuestmasterCore

/// Shared shell layout metrics and the selected-session chip value type. The
/// interactive AppKit controls that used to live here (segmented pills, icon
/// button, session chip view, status leaves) are now SwiftUI — see
/// `ShellChromeControls.swift`, `ShellTopBars.swift`, and `ShellStatusViews.swift`.

enum ShellMetrics {
    static let dockTopBarHeight: CGFloat = 40
    /// Empty space above the first tracker header, matching the mockup's spacing.
    static let trackerTopInset: CGFloat = 25
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
    static let sideCardInset = Token.Spacing.card
    static let sideCardCornerRadius = Token.Radius.card
    /// Window edge to the tracker plates and plates to the terminal pane add up to the same 20pt as
    /// Ghostty's own `window-padding-x` against the terminal's other three sides (2026-10-02): the
    /// tracker now sits flush against the terminal, so Ghostty's padding alone makes up that side.
    static let trackerLeadingInset = Token.Spacing.element
    static let trackerTrailingGap: CGFloat = 0
    static let splitLayoutMetrics = ShellSplitLayoutMetrics(
        sideCardInset: Double(sideCardInset),
        dockDividerHitWidth: 7,
        trackerMaxWidth: 300,
        trackerLeadingInset: Double(trackerLeadingInset),
        trackerTrailingGap: Double(trackerTrailingGap)
    )
}

struct SelectedSessionChip: Equatable {
    let title: String
    let id: String
    let agent: String
}
