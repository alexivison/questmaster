import Foundation

/// Which content the dock shows for a session. `.artifacts` means the artifact
/// viewer is open; `.board` is the default quest board.
public enum SessionDockMode: String, Equatable {
    case board
    case artifacts
}

/// Per-session, in-memory UI state that is restored when the session is viewed again.
/// Defaults reproduce today's first-launch behavior (dock hidden, board mode).
public struct SessionUIState: Equatable {
    public var dockVisible: Bool
    public var dockMode: SessionDockMode

    public init(dockVisible: Bool = false, dockMode: SessionDockMode = .board) {
        self.dockVisible = dockVisible
        self.dockMode = dockMode
    }

    public static let initial = SessionUIState()
}
