import Foundation

/// The dock's navigation state: which screen it shows. The artifact viewer has two
/// screens (the list and a single open artifact), so this is three states, not two.
public enum DockContent: Equatable {
    case board
    case artifactList
    case artifactViewer
}

/// Per-session, in-memory UI state that is restored when the session is viewed again.
/// Defaults reproduce today's first-launch behavior (dock hidden, board content).
///
/// This captures the dock *navigation* (is it open, and which screen). The *selected
/// artifact* is content, owned per-session by `ArtifactDisplayState`.
public struct SessionUIState: Equatable {
    public var dockVisible: Bool
    public var dockContent: DockContent

    public init(dockVisible: Bool = false, dockContent: DockContent = .board) {
        self.dockVisible = dockVisible
        self.dockContent = dockContent
    }

    public static let initial = SessionUIState()
}
