import Foundation

/// Per-session, in-memory UI state that is restored when the session is viewed again.
/// Defaults reproduce today's first-launch behavior (dock hidden, board mode).
public struct SessionUIState: Equatable {
    public var dockVisible: Bool
    /// Whether the dock shows the artifact viewer (vs the default quest board).
    public var artifactsOpen: Bool

    public init(dockVisible: Bool = false, artifactsOpen: Bool = false) {
        self.dockVisible = dockVisible
        self.artifactsOpen = artifactsOpen
    }

    public static let initial = SessionUIState()
}
