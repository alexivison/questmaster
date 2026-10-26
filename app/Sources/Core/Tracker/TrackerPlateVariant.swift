import Foundation

/// Which nameplate a plate row draws: a master draws the top-level plate (project bar, elapsed time), a worker, which
/// hangs under a master, the worker plate. Shell, tmux and orphan rows draw no plate: they are the shell section's list
/// rows (`TrackerShellSection`), so they have no variant.
public enum TrackerPlateVariant: Equatable {
    case topLevel
    case worker

    public init?(role: SessionRoleKind) {
        switch role {
        case .master:
            self = .topLevel
        case .worker:
            self = .worker
        case .shell, .tmux, .orphan:
            return nil
        }
    }
}
