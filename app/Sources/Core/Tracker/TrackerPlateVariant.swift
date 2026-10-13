import Foundation

/// Which nameplate a tracker row draws. Masters and standalone sessions share the top-level plate
/// (project bar, elapsed time); only a worker, which hangs under a master, draws the worker plate.
public enum TrackerPlateVariant: Equatable {
    case topLevel
    case worker

    public init(role: SessionRoleKind) {
        self = role == .worker ? .worker : .topLevel
    }
}
