import Foundation

/// Which plate shape the session panel shows, per the brief: a shield for a master, a notched
/// circle for a standalone session, and a plain-ended circle otherwise (a worker, or no
/// selection) — the same three shapes `TrackerPlatePaths.Kind` already draws for the tracker.
public enum ActionBarSessionPanelVariant: Equatable {
    case master
    case standalone
    case worker

    public init(role: SessionRoleKind?) {
        switch role {
        case .master:
            self = .master
        case .standalone:
            self = .standalone
        case .worker, .tmux, .orphan, nil:
            self = .worker
        }
    }
}
