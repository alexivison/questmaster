import QuestmasterCore

/// The Artifacts list's Session/All tabs. The dock's top bar draws them (`DockTopBar`), not the list: the bar's 40pt band
/// holds them, between the plate and the list.
extension ArtifactScope {
    static var dockCases: [ArtifactScope] {
        [.session, .all]
    }

    var title: String {
        switch self {
        case .session:
            return "Session"
        case .project:
            return "Project"
        case .all:
            return "All"
        }
    }
}

enum ArtifactScopeTabsMetrics {
    /// The row's top in the bar: its label's baseline (`TextTabMetrics.labelBaseline`) sits on the bar's bottom edge, so the
    /// label's top stands about 15 under the title plate's bottom edge, as the mock has it.
    static let top = ShellMetrics.dockTopBarHeight - TextTabMetrics.labelBaseline
    /// The row's room either side: the bar's inset, the close button's icon and `Space.item`, so the tabs centre on the panel
    /// and stop `Space.item` short of the close button.
    static let sideInset = ShellMetrics.dockTopBarHorizontalInset + ChromeMetrics.iconWidth + Space.item
}
