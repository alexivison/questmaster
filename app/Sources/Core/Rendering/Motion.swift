import Foundation

/// The app's one-shot motion steps (AGENTS.md, "Motion"). A small change (a toggle, a fade-out, a page swap) takes
/// `fast`; a panel, a modal or a layout move takes `standard`. Every one-shot transition names one, so the app moves
/// at two paces and no view states its own duration.
public enum MotionStep: Equatable, Sendable {
    case fast
    case standard

    public var seconds: TimeInterval {
        switch self {
        case .fast: 0.12
        case .standard: 0.18
        }
    }

    /// How long the step runs: none when the system asks for less motion. Reduce Motion skips a transition, it
    /// doesn't shorten it.
    public func duration(reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? 0 : seconds
    }
}

/// The one easing: ease out, quick at first and settling, as a cubic Bézier. These are the control points of the
/// system's own `.easeOut` (`CAMediaTimingFunction`, SwiftUI's `Animation`), so Core Animation, SwiftUI and a
/// hand-stepped transition all trace the same curve.
public enum MotionEasing {
    public static let controlPoints = (x1: 0.0, y1: 0.0, x2: 0.58, y2: 1.0)

    /// The curve's progress at `time` (0 to 1, clamped), for a transition stepped by hand.
    public static func eased(_ time: Double) -> Double {
        guard time > 0 else { return 0 }
        guard time < 1 else { return 1 }
        // Find the parameter whose x is `time`, then read y there.
        var low = 0.0
        var high = 1.0
        for _ in 0..<24 {
            let middle = (low + high) / 2
            if bezier(middle, controlPoints.x1, controlPoints.x2) < time {
                low = middle
            } else {
                high = middle
            }
        }
        return bezier((low + high) / 2, controlPoints.y1, controlPoints.y2)
    }

    /// One axis of a cubic Bézier from 0 to 1 with control values `first` and `second`, at parameter `t`.
    private static func bezier(_ t: Double, _ first: Double, _ second: Double) -> Double {
        let inverse = 1 - t
        return 3 * inverse * inverse * t * first + 3 * inverse * t * t * second + t * t * t
    }
}
