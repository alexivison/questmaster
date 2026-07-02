import Foundation

/// The dock's navigation state: which artifact screen it shows.
public enum DockContent: Equatable {
    case artifactList
    case artifactViewer
}

/// Per-session, in-memory view state projected into the dock when the session is viewed.
/// Defaults reproduce first-launch behavior (dock hidden, artifact list).
public struct SessionViewState: Equatable {
    public var dockVisible: Bool
    public var dockContent: DockContent
    public var selectedArtifactID: String?
    public var dockPreferredWidth: Double?
    public var artifactScope: ArtifactScope

    public init(
        dockVisible: Bool = false,
        dockContent: DockContent = .artifactList,
        selectedArtifactID: String? = nil,
        dockPreferredWidth: Double? = nil,
        artifactScope: ArtifactScope = .session
    ) {
        self.dockVisible = dockVisible
        self.dockContent = dockContent
        self.selectedArtifactID = selectedArtifactID
        self.dockPreferredWidth = dockPreferredWidth
        self.artifactScope = artifactScope
    }

    public static let initial = SessionViewState()
}
