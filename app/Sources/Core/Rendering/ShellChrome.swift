import Foundation

/// Pure presentation decisions for the shell top-bar chrome (region tabs, dock
/// tabs/back-targets, serve-status pill). Colors/fonts stay in the app token
/// layer; this file only decides *what* the chrome shows, keyed off
/// UI-independent state, so both the decision and its edge cases stay testable.

/// One segment of a segmented pill control (rendered by the app's `ChromePillControl`).
public struct ShellPillSegment: Equatable {
    public let title: String
    public let isActive: Bool
    public let isStruck: Bool

    public init(title: String, isActive: Bool, isStruck: Bool = false) {
        self.title = title
        self.isActive = isActive
        self.isStruck = isStruck
    }
}

/// The terminal top-bar region tabs (Tracker / Terminal / Dock). `order` is the
/// fixed positional mapping the pill control uses to translate a tapped index
/// back into a `FocusRegion`.
public enum ShellRegionTabs {
    public static let order: [FocusRegion] = [.tracker, .terminal, .dock]

    public static func segments(for navigation: AppNavigationState) -> [ShellPillSegment] {
        [
            ShellPillSegment(
                title: "Tracker",
                isActive: navigation.focusedRegion == .tracker && navigation.trackerVisible,
                isStruck: !navigation.trackerVisible
            ),
            ShellPillSegment(title: "Terminal", isActive: navigation.focusedRegion == .terminal),
            ShellPillSegment(
                title: "Dock",
                isActive: navigation.focusedRegion == .dock && navigation.dockVisible,
                isStruck: !navigation.dockVisible
            ),
        ]
    }
}

/// What content the dock pane is showing — its board-vs-artifacts mode.
public enum DockContentMode: Equatable {
    case board
    case artifacts
}

/// Where the artifact area of the dock currently is.
public enum ArtifactDockRoute: Equatable {
    case list
    case viewer
}

/// Fully resolved dock top-bar layout: which back affordance (if any), the
/// optional title, and whether the section tabs vs. an artifact's actions show.
public struct DockTopBarModel: Equatable {
    public enum Back: Equatable {
        case questList
        case artifactList
    }

    public let back: Back?
    public let title: String?
    public let showSectionTabs: Bool
    public let sectionSegments: [ShellPillSegment]
    public let showArtifactActions: Bool

    public init(
        back: Back?,
        title: String?,
        showSectionTabs: Bool,
        sectionSegments: [ShellPillSegment],
        showArtifactActions: Bool
    ) {
        self.back = back
        self.title = title
        self.showSectionTabs = showSectionTabs
        self.sectionSegments = sectionSegments
        self.showArtifactActions = showArtifactActions
    }

    public static func make(
        snapshot: RuntimeSnapshot?,
        selectedSection: QuestBoardSection,
        mode: DockContentMode,
        questRoute: QuestDockRoute,
        questTitle: String?,
        artifactRoute: ArtifactDockRoute,
        artifactTitle: String?
    ) -> DockTopBarModel {
        guard mode == .board else {
            let viewingArtifact = artifactRoute == .viewer
            return DockTopBarModel(
                back: viewingArtifact ? .artifactList : nil,
                title: viewingArtifact ? (artifactTitle ?? "Artifact") : "Artifacts",
                showSectionTabs: false,
                sectionSegments: [],
                showArtifactActions: viewingArtifact
            )
        }
        let viewingQuest = questRoute == .detail
        guard !viewingQuest else {
            return DockTopBarModel(
                back: .questList,
                title: questTitle ?? "Quest detail",
                showSectionTabs: false,
                sectionSegments: [],
                showArtifactActions: false
            )
        }
        let snapshot = snapshot ?? .empty(sourceLabel: "")
        let segments = QuestBoardSection.allCases.map { section in
            ShellPillSegment(
                title: "\(section.title) \(QuestBoardLogic.count(in: snapshot, section: section))",
                isActive: section == selectedSection
            )
        }
        return DockTopBarModel(
            back: nil,
            title: nil,
            showSectionTabs: true,
            sectionSegments: segments,
            showArtifactActions: false
        )
    }
}

/// The serve-status pill's text + indicator. The pill's colors are derived from
/// `ServeConnectionState` in the app token layer; this only fixes the copy and
/// whether the indicator is a static dot or an animated spinner.
public struct ServePillDisplay: Equatable {
    public enum Indicator: Equatable {
        case dot
        case spinner
    }

    public let label: String
    public let indicator: Indicator

    public init(label: String, indicator: Indicator) {
        self.label = label
        self.indicator = indicator
    }

    public static func make(_ state: ServeConnectionState) -> ServePillDisplay {
        switch state {
        case .ready:
            return ServePillDisplay(label: "serve", indicator: .dot)
        case .starting:
            return ServePillDisplay(label: "starting serve…", indicator: .spinner)
        case .error:
            return ServePillDisplay(label: "serve error", indicator: .dot)
        }
    }
}
