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

        /// Whether the flight travels leftward, as a returning wisp does. A class draws a flight's frames facing right, so the overlay
        /// mirrors them on a flight that heads left, and the head leads either way.
        public var headsLeft: Bool {
            to.x < from.x
        }
    }

    /// The route of one flight. A flight from the avatar's hand lands on the Worker Log's left edge, or off the window's right edge
    /// when no Worker Log shows. A returning flight starts at that same point and lands on the hand, which is always on screen.
    /// `trail` is how far the flying art reaches behind the point that rides the path, in points: a flight that leaves the window
    /// ends far enough past its edge that the trail is out of view too.
    public static func route(
        for flight: TrackerSpellFlight, hand: TrackerSpellPoint, workerLog: ShellSplitRect?, window: ShellSplitRect, trail: Double = 0
    ) -> Route {
        let edge = edge(hand: hand, workerLog: workerLog, window: window, trail: trail)
        switch flight.from {
        case .avatar:
            return Route(from: hand, to: edge, impactsAtEnd: workerLog != nil)
        case .worker:
            return Route(from: edge, to: hand, impactsAtEnd: true)
        }
    }

    /// The point the flights meet: the Worker Log's left edge, level with the hand and clamped into the panel's height, or the point
    /// just off the window's right edge at the hand's height when no Worker Log shows. Every worker's flights meet it.
    static func edge(hand: TrackerSpellPoint, workerLog: ShellSplitRect?, window: ShellSplitRect, trail: Double = 0) -> TrackerSpellPoint {
        guard let workerLog else {
            return TrackerSpellPoint(x: window.maxX + max(offscreenOvershoot, trail), y: hand.y)
        }
        return TrackerSpellPoint(x: workerLog.x, y: min(max(hand.y, workerLog.y), workerLog.maxY))
    }
}
