import Foundation

/// What the bottom dock panel shows.
public enum DockContent: Equatable {
    case artifactList
    case artifactViewer
    case workerChat
}

/// The dock's two stacked panels: Version Control on top, and under it whatever `DockContent` names.
public enum DockPanel: Equatable {
    case top
    case bottom
}

/// Which of the dock's panels show.
public struct DockPanels: Equatable {
    public var top: Bool
    public var bottom: Bool

    public init(top: Bool = false, bottom: Bool = false) {
        self.top = top
        self.bottom = bottom
    }

    /// The dock region shows while either panel does.
    public var isShown: Bool {
        top || bottom
    }

    public func contains(_ panel: DockPanel) -> Bool {
        switch panel {
        case .top: top
        case .bottom: bottom
        }
    }
}

/// The dock's state, app-wide: switching sessions never opens, closes, swaps or resizes a panel. Only what they list
/// follows the session (the Session tab's artifacts, the worker chat's workers, Version Control's pull requests). The
/// open artifact stays across sessions: the viewer may show another session's artifact, as the All tab lists them
/// anyway. In memory only.
///
/// The two panels are independent: Version Control (top) opens and closes without touching the bottom panel, and what
/// the bottom panel shows changes without touching Version Control.
public struct DockState: Equatable {
    /// Version Control, the top panel.
    public var topVisible: Bool
    /// The bottom panel: `dockContent` names what it shows.
    public var bottomVisible: Bool
    public var dockContent: DockContent
    /// The viewer's open artifact, and the list's cursor.
    public var selectedArtifactID: String?
    public var dockPreferredWidth: Double?
    public var artifactScope: ArtifactScope
    public var artifactFilterQuery: String
    public var artifactFilterTokens: [ArtifactFilterToken]

    public init(
        topVisible: Bool = false,
        bottomVisible: Bool = false,
        dockContent: DockContent = .artifactList,
        selectedArtifactID: String? = nil,
        dockPreferredWidth: Double? = nil,
        artifactScope: ArtifactScope = .session,
        artifactFilterQuery: String = "",
        artifactFilterTokens: [ArtifactFilterToken] = []
    ) {
        self.topVisible = topVisible
        self.bottomVisible = bottomVisible
        self.dockContent = dockContent
        self.selectedArtifactID = selectedArtifactID
        self.dockPreferredWidth = dockPreferredWidth
        self.artifactScope = artifactScope
        self.artifactFilterQuery = artifactFilterQuery
        self.artifactFilterTokens = artifactFilterTokens
    }

    /// First launch: both panels hidden, the bottom one on the artifact list.
    public static let initial = DockState()

    /// Shows `content` in the bottom panel, opening it if it's hidden. The top panel stays as it was.
    public mutating func show(_ content: DockContent) {
        bottomVisible = true
        dockContent = content
        if content == .workerChat {
            selectedArtifactID = nil
        }
    }

    public mutating func showArtifact(_ artifactID: String) {
        bottomVisible = true
        dockContent = .artifactViewer
        selectedArtifactID = artifactID
    }

    public mutating func setArtifactScope(_ scope: ArtifactScope) {
        artifactScope = scope
        selectedArtifactID = nil
        dockContent = .artifactList
    }

    /// Which panels show: with no session (a detached terminal) both hide, and their state stays, so they come back
    /// as they were when a session attaches.
    public func panels(hasSession: Bool) -> DockPanels {
        DockPanels(top: topVisible && hasSession, bottom: bottomVisible && hasSession)
    }

    /// A new artifact in the viewed session opens in the viewer, opening the bottom panel if it's hidden, but never over
    /// the worker chat while it shows. Returns whether it opened.
    public mutating func openNewArtifact(_ artifactID: String) -> Bool {
        guard !(bottomVisible && dockContent == .workerChat) else {
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
