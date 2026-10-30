import Foundation

/// A point in the window's top-left coordinates, the way the avatar's hand point is.
public struct TrackerSpellPoint: Equatable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Where a spell's flight starts and ends across the window. Points are in the window's top-left coordinates, and rects use the
/// same origin (`y` is the top edge). A flight from the avatar runs to the Worker Log's left edge, or off the window's right edge
/// when no Worker Log shows. A returning flight runs back the other way. Core decides the ends; the overlay draws them.
public enum TrackerSpellPath {
    /// How far past the window's right edge a flight ends when no Worker Log shows: far enough that its art is out of view.
    public static let offscreenOvershoot: Double = 40

    public struct Route: Equatable {
        public let from: TrackerSpellPoint
        public let to: TrackerSpellPoint
        /// Whether the impact frame plays at `to`: only where the flight lands on screen.
        public let impactsAtEnd: Bool

        public init(from: TrackerSpellPoint, to: TrackerSpellPoint, impactsAtEnd: Bool) {
            self.from = from
            self.to = to
            self.impactsAtEnd = impactsAtEnd
        }
    }

    /// The route of one flight. A flight from the avatar's hand lands on the Worker Log's left edge, or off the window's right edge
    /// when no Worker Log shows. A returning flight starts at that same point and lands on the hand, which is always on screen.
    public static func route(for flight: TrackerSpellFlight, hand: TrackerSpellPoint, workerLog: ShellSplitRect?, window: ShellSplitRect) -> Route {
        let edge = edge(hand: hand, workerLog: workerLog, window: window)
        switch flight.from {
        case .avatar:
            return Route(from: hand, to: edge, impactsAtEnd: workerLog != nil)
        case .worker:
            return Route(from: edge, to: hand, impactsAtEnd: true)
        }
    }

    /// The point the flights meet: the Worker Log's left edge, level with the hand and clamped into the panel's height, or the point
    /// just off the window's right edge at the hand's height when no Worker Log shows. Every worker's flights meet it.
    static func edge(hand: TrackerSpellPoint, workerLog: ShellSplitRect?, window: ShellSplitRect) -> TrackerSpellPoint {
        guard let workerLog else {
            return TrackerSpellPoint(x: window.maxX + offscreenOvershoot, y: hand.y)
        }
        return TrackerSpellPoint(x: workerLog.x, y: min(max(hand.y, workerLog.y), workerLog.maxY))
    }
}
