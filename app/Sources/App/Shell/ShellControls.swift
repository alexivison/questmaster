import AppKit
import QuestmasterCore

/// Shared shell layout metrics and the selected-session chip value type. The
/// interactive AppKit controls that used to live here (segmented pills, icon
/// button, session chip view, status leaves) are now SwiftUI — see
/// `ShellChromeControls.swift`, `ShellTopBarViews.swift`, and `ShellStatusViews.swift`.

enum ShellMetrics {
    static let topBarHeight = CGFloat(ShellSplitMetrics.topBarHeight)
    static let trafficLightReserve = CGFloat(ShellSplitMetrics.trafficLightReserve)
    static let sideCardInset = CGFloat(ShellSplitMetrics.sideCardInset)
    static let sideCardCornerRadius = CGFloat(ShellSplitMetrics.sideCardCornerRadius)
}

struct SelectedSessionChip {
    let title: String
    let id: String
    let agent: String
}
