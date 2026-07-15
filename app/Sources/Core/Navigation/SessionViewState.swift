import Foundation

/// The dock's navigation state: which artifact screen it shows.
public enum DockContent: Equatable {
    case artifactList
    case artifactViewer
    case questList
}

/// Per-session, in-memory view state projected into the dock when the session is viewed.
/// Defaults reproduce first-launch behavior (dock hidden, artifact list).
public struct SessionViewState: Equatable {
    public var dockVisible: Bool
    public var dockContent: DockContent
    public var selectedArtifactID: String?
    public var selectedQuestID: String?
    public var dockPreferredWidth: Double?
    public var artifactScope: ArtifactScope
    public var artifactFilterQuery: String
    public var artifactFilterTokens: [ArtifactFilterToken]

    public init(
        dockVisible: Bool = false,
        dockContent: DockContent = .artifactList,
        selectedArtifactID: String? = nil,
        selectedQuestID: String? = nil,
        dockPreferredWidth: Double? = nil,
        artifactScope: ArtifactScope = .session,
        artifactFilterQuery: String = "",
        artifactFilterTokens: [ArtifactFilterToken] = []
    ) {
        self.dockVisible = dockVisible
        self.dockContent = dockContent
        self.selectedArtifactID = selectedArtifactID
        self.selectedQuestID = selectedQuestID
        self.dockPreferredWidth = dockPreferredWidth
        self.artifactScope = artifactScope
        self.artifactFilterQuery = artifactFilterQuery
        self.artifactFilterTokens = artifactFilterTokens
    }

    public static let initial = SessionViewState()
}
