import Foundation

/// Resolves which workers belong to the attached session's group: a master's own workers, a
/// worker's siblings (itself highlighted), or nothing for a standalone session or no selection.
public enum AttachedWorkerGroupResolver {
    public struct Resolution: Equatable {
        public let workers: [TrackerSession]
        public let highlightedWorkerID: String?

        public init(workers: [TrackerSession], highlightedWorkerID: String?) {
            self.workers = workers
            self.highlightedWorkerID = highlightedWorkerID
        }

        public static let empty = Resolution(workers: [], highlightedWorkerID: nil)
    }

    public static func resolve(selectedSessionID: String?, sessions: [TrackerSession]) -> Resolution {
        guard let selectedSessionID,
              let selected = sessions.first(where: { $0.id == selectedSessionID }) else {
            return .empty
        }
        switch SessionRoleKind(role: selected.role) {
        case .master:
            return Resolution(
                workers: sessions.filter { $0.parentID == selected.id },
                highlightedWorkerID: nil
            )
        case .worker:
            return Resolution(
                workers: sessions.filter { $0.parentID == selected.parentID },
                highlightedWorkerID: selected.id
            )
        case .standalone, .tmux, .orphan:
            return .empty
        }
    }
}
