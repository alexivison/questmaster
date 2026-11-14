import Foundation

/// How the idle fidgets are spaced, in seconds. A fidget's own frames and times come from the class's `animation.json`.
public enum TrackerAvatarFidgetTiming {
    /// How long he idles between one fidget and the next: a random time in this range.
    public static let gapSeconds: ClosedRange<TimeInterval> = 8...15
}

/// What the idle pose shows at one instant: a fidget's art frame, or nil while he breathes at rest.
public struct TrackerAvatarFidgetFrame: Equatable {
    public let artFrame: Int?
    /// When the frame next changes on its own; nil when it won't.
    public let nextChange: TimeInterval?
}

/// The idle fidgets, decided here. While idle he waits a random gap (`TrackerAvatarFidgetTiming.gapSeconds`), then plays one
/// fidget in place and goes back to breathing. A fidget never follows the same fidget. A fidget whose art is missing is skipped,
/// and its slot stays empty. Any other pose stops a fidget at once, and none play under Reduce Motion. The random picks come from
/// `random`, so a seeded generator makes them repeatable in tests.
public struct TrackerAvatarFidgets<Generator: RandomNumberGenerator> {
    private struct Playing {
        let fidget: TrackerAvatarIdleFidget
        let start: TimeInterval

        /// The same running sum the steps use, so the end and the last step agree to the bit.
        var end: TimeInterval {
            fidget.track.steps.reduce(start) { $0 + $1.seconds }
        }
    }

    private let available: [TrackerAvatarIdleFidget]
    private let reducesMotion: Bool
    private var random: Generator
    /// When the next fidget is due, while he idles.
    private var due: TimeInterval?
    private var current: Playing?
    /// The fidget that played last, which the next one may not be.
    private var last: TrackerAvatarIdleFidget?

    /// `available` lists the fidgets whose art has landed, in the order the file gives them.
    public init(available: [TrackerAvatarIdleFidget], reducesMotion: Bool, random: Generator) {
        self.available = available
        self.reducesMotion = reducesMotion
        self.random = random
    }

    /// The frame at `now`, for the pose the session holds (nil when it shows no avatar).
    public mutating func frame(pose: TrackerAvatarPose?, at now: TimeInterval) -> TrackerAvatarFidgetFrame {
        guard pose == .idle, !reducesMotion else {
            due = nil
            current = nil
            return TrackerAvatarFidgetFrame(artFrame: nil, nextChange: nil)
        }
        if let current {
            if now < current.end {
                return Self.stepFrame(of: current, at: now)
            }
            finish(current)
        }
        let start = due ?? (now + gap())
        due = start
        guard now >= start else {
            return TrackerAvatarFidgetFrame(artFrame: nil, nextChange: start)
        }
        guard let fidget = pickFidget() else {
            // Nothing can play this time. Forget the last fidget, so a lone one can come round again on the next gap.
            last = nil
            due = now + gap()
            return TrackerAvatarFidgetFrame(artFrame: nil, nextChange: due)
        }
        let started = Playing(fidget: fidget, start: start)
        guard now < started.end else {
            // The call came after the whole fidget had played.
            finish(started)
            return TrackerAvatarFidgetFrame(artFrame: nil, nextChange: due)
        }
        current = started
        return Self.stepFrame(of: started, at: now)
    }

    private mutating func finish(_ playing: Playing) {
        last = playing.fidget
        current = nil
        due = playing.end + gap()
    }

    private mutating func gap() -> TimeInterval {
        Double.random(in: TrackerAvatarFidgetTiming.gapSeconds, using: &random)
    }

    private mutating func pickFidget() -> TrackerAvatarIdleFidget? {
        let candidates = available.filter { $0 != last }
        return candidates.randomElement(using: &random)
    }

    /// The step showing at `now`, and when it gives way to the next.
    private static func stepFrame(of playing: Playing, at now: TimeInterval) -> TrackerAvatarFidgetFrame {
        var start = playing.start
        for step in playing.fidget.track.steps {
            let end = start + step.seconds
            if now < end {
                return TrackerAvatarFidgetFrame(artFrame: step.frame, nextChange: end)
            }
            start = end
        }
        return TrackerAvatarFidgetFrame(artFrame: nil, nextChange: nil)
    }
}
