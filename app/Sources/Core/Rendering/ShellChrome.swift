import Foundation

/// Pure presentation decisions for the shell top-bar chrome (dock back-targets).
/// Colors/fonts stay in the app token layer; this file only decides *what* the
/// chrome shows, keyed off UI-independent state, so both the decision and its
/// edge cases stay testable.

/// What content the dock pane is showing.
public enum DockContentMode: Equatable {
    case artifacts
    case quests
}

/// Where the artifact area of the dock currently is.
public enum ArtifactDockRoute: Equatable {
    case list
    case viewer
}

/// Fully resolved dock top-bar layout: which back affordance (if any), the
/// optional title, and whether an artifact's actions show.
public struct DockTopBarModel: Equatable {
    public enum Back: Equatable {
        case artifactList
    }

    public let back: Back?
    public let title: String?
    public let showArtifactActions: Bool

    public init(
        back: Back?,
        title: String?,
        showArtifactActions: Bool
    ) {
        self.back = back
        self.title = title
        self.showArtifactActions = showArtifactActions
    }

    public static func make(
        mode: DockContentMode,
        artifactRoute: ArtifactDockRoute,
        artifactTitle: String?
    ) -> DockTopBarModel {
        let viewingArtifact = mode == .artifacts && artifactRoute == .viewer
        return DockTopBarModel(
            back: viewingArtifact ? .artifactList : nil,
            title: mode == .quests ? "Quests" : (viewingArtifact ? (artifactTitle ?? "Artifact") : "Artifacts"),
            showArtifactActions: viewingArtifact
        )
    }
}
