import Foundation

/// What the dock shows.
public enum DockContent: Equatable {
    case artifactList
    case artifactViewer
    case workerChat
    case versionControl

    /// The artifact list and viewer, as opposed to the dock's other surfaces.
    public var isArtifact: Bool {
        self == .artifactList || self == .artifactViewer
    }
}

/// The dock's state, app-wide: switching sessions never opens, closes, swaps or resizes the dock. Only what it lists
/// follows the session (the Session tab's artifacts, the worker chat's workers, the version control dock's pull requests). The open artifact stays across
/// sessions: the viewer may show another session's artifact, as the All tab lists them anyway. In memory only.
public struct DockState: Equatable {
    public var dockVisible: Bool
    public var dockContent: DockContent
    /// The viewer's open artifact, and the list's cursor.
    public var selectedArtifactID: String?
    public var dockPreferredWidth: Double?
    public var artifactScope: ArtifactScope
    public var artifactFilterQuery: String
    public var artifactFilterTokens: [ArtifactFilterToken]

    public init(
        dockVisible: Bool = false,
        dockContent: DockContent = .artifactList,
        selectedArtifactID: String? = nil,
        dockPreferredWidth: Double? = nil,
        artifactScope: ArtifactScope = .session,
        artifactFilterQuery: String = "",
        artifactFilterTokens: [ArtifactFilterToken] = []
    ) {
        self.dockVisible = dockVisible
        self.dockContent = dockContent
        self.selectedArtifactID = selectedArtifactID
        self.dockPreferredWidth = dockPreferredWidth
        self.artifactScope = artifactScope
        self.artifactFilterQuery = artifactFilterQuery
        self.artifactFilterTokens = artifactFilterTokens
    }

    /// First launch: hidden, on the artifact list.
    public static let initial = DockState()

    public mutating func show(_ content: DockContent) {
        dockVisible = true
        dockContent = content
        if !content.isArtifact {
            selectedArtifactID = nil
        }
    }

    public mutating func showArtifact(_ artifactID: String) {
        dockVisible = true
        dockContent = .artifactViewer
        selectedArtifactID = artifactID
    }

    public mutating func setArtifactScope(_ scope: ArtifactScope) {
        artifactScope = scope
        selectedArtifactID = nil
        dockContent = .artifactList
    }

    /// Whether the dock shows: with no session (a detached terminal) it hides, and its state stays, so it comes back
    /// as it was when a session attaches.
    public func isShown(hasSession: Bool) -> Bool {
        dockVisible && hasSession
    }

    /// A new artifact in the viewed session opens in the viewer, opening the dock if it's hidden, but never over the
    /// worker chat or the version control dock while one shows. Returns whether it opened.
    public mutating func openNewArtifact(_ artifactID: String) -> Bool {
        guard !(dockVisible && !dockContent.isArtifact) else {
            return false
        }
        showArtifact(artifactID)
        return true
    }

    /// What the list shows changed (a render, a session switch): its cursor follows. The viewer keeps its artifact.
    public mutating func followList(selectedArtifactID artifactID: String?) {
        guard dockContent == .artifactList else {
            return
        }
        selectedArtifactID = artifactID
    }
}
