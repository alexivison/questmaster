import Foundation

/// Tracks a pending `g` keypress toward a vim-style `gg` (jump-to-top) chord. A lone `g` arms the
/// tracker; a second `g` within the window resolves to `.jumpToTop`. Any other key must call
/// `reset()` instead of `handleG()` so it is never swallowed by a stale pending `g`.
public struct GPrefixTracker {
    private static let window: TimeInterval = 0.6

    private var pendingSince: Date?

    public init() {}

    public enum Resolution: Equatable {
        case pendingSecondG
        case jumpToTop
    }

    public mutating func handleG(now: Date = Date()) -> Resolution {
        if let pendingSince, now.timeIntervalSince(pendingSince) <= Self.window {
            self.pendingSince = nil
            return .jumpToTop
        }
        pendingSince = now
        return .pendingSecondG
    }

    public mutating func reset() {
        pendingSince = nil
    }
}
