import Foundation

/// Pure presentation decisions for the shell top-bar chrome (dock back-targets).
/// Colors/fonts stay in the app token layer; this file only decides *what* the
/// chrome shows, keyed off UI-independent state, so both the decision and its
/// edge cases stay testable.

/// What the bottom dock panel is showing.
public enum DockContentMode: Equatable {
    case artifacts
    case workerChat
}

/// Where the artifact area of the dock currently is.
public enum ArtifactDockRoute: Equatable {
    case list
    case viewer
}

/// Fully resolved dock top-bar layout: which back affordance (if any), the
/// optional title, and whether an artifact's actions or the worker log's filter show.
/// The filter shows only while the worker log is attached to a master, the one case it can open.
public struct DockTopBarModel: Equatable {
    public enum Back: Equatable {
        case artifactList
    }

    public let back: Back?
    public let title: String?
    public let showArtifactActions: Bool
    public let showsLogFilter: Bool
    /// The Artifacts list's Session/All tabs, with the scope they show as selected; nil where the bar has no tabs.
    public let artifactScope: ArtifactScope?

    public init(
        back: Back?,
        title: String?,
        showArtifactActions: Bool,
        showsLogFilter: Bool,
        artifactScope: ArtifactScope? = nil
    ) {
        self.back = back
        self.title = title
        self.showArtifactActions = showArtifactActions
        self.showsLogFilter = showsLogFilter
        self.artifactScope = artifactScope
    }

    /// The top panel's bar: its title and the close button, nothing else.
    public static let watcher = DockTopBarModel(back: nil, title: "Watcher", showArtifactActions: false, showsLogFilter: false)

    public static func make(
        mode: DockContentMode,
        artifactRoute: ArtifactDockRoute,
        artifactTitle: String?,
        logAttached: Bool,
        artifactScope: ArtifactScope? = nil
    ) -> DockTopBarModel {
        let viewingArtifact = mode == .artifacts && artifactRoute == .viewer
        let listingArtifacts = mode == .artifacts && artifactRoute == .list
        return DockTopBarModel(
            back: viewingArtifact ? .artifactList : nil,
            title: title(mode: mode, viewingArtifact: viewingArtifact, artifactTitle: artifactTitle),
            showArtifactActions: viewingArtifact,
            showsLogFilter: mode == .workerChat && logAttached,
            artifactScope: listingArtifacts ? artifactScope : nil
        )
    }

    private static func title(mode: DockContentMode, viewingArtifact: Bool, artifactTitle: String?) -> String {
        switch mode {
        case .workerChat:
            return "Worker Log"
        case .artifacts:
            return viewingArtifact ? (artifactTitle ?? "Artifact") : "Artifacts"
        }
    }
}
