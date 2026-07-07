import AppKit
import QuestmasterCore

/// Shared shell layout metrics and the selected-session chip value type. The
/// interactive AppKit controls that used to live here (segmented pills, icon
/// button, session chip view, status leaves) are now SwiftUI — see
/// `ShellChromeControls.swift`, `ShellTopBars.swift`, and `ShellStatusViews.swift`.

enum ShellMetrics {
    static let topBarHeight: CGFloat = 46
    static let trafficLightReserve: CGFloat = 78
    static let sideCardInset = Token.Spacing.card
    static let sideCardCornerRadius = Token.Radius.card
    static let splitLayoutMetrics = ShellSplitLayoutMetrics(
        sideCardInset: Double(sideCardInset),
        dockDividerHitWidth: 7,
        trackerMaxWidth: 300
    )
}

struct SelectedSessionChip: Equatable {
    let title: String
    let id: String
    let agent: String
}
