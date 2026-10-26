import Foundation

/// Which nameplate a plate row draws: a master draws the top-level plate (project bar, elapsed time), a worker, which
/// hangs under a master, the worker plate. Shell rows draw no plate (`TrackerShellSection`).
public enum TrackerPlateVariant: Equatable {
    case topLevel
    case worker

    public init(role: SessionRoleKind) {
        self = role == .worker ? .worker : .topLevel
    }
}
