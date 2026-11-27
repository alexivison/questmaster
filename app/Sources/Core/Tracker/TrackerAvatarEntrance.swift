import Foundation

/// A familiar's entrance: the animation it plays when a worker joins its master's company, read from the `entrance` object of a company
/// size's `animation.json`. The art is authored on the 0.05 s `MotionTick`, and plays at `TrackerAvatarAnimation.playbackSpeed` like every other
/// avatar animation: each tick is the authored one divided by that speed (`tickSeconds`). Each part is one image drawn on the figure's canvas, moved by
/// whole device pixels and cropped to a window, so the offsets, clips and copies are data the App places; the effect layers behind and in
/// front are images placed at `origin`. The entrance ends on the figure's rest, so the familiar's idle takes over where it stops.
public struct TrackerAvatarEntrance: Equatable, Sendable {
    /// The image a part draws when its step names none: the company's still frame.
    public static let stillFile = "01-idle-f1.png"

    /// A point on the figure's canvas, in device pixels from its top left.
    public struct Origin: Equatable, Sendable {
        public let x: Int
        public let y: Int

        public init(x: Int, y: Int) {
            self.x = x
            self.y = y
        }
    }

    /// The part of an image a step draws: columns `x0..<x1` and rows `y0..<y1`, in the image's own pixels.
    public struct Window: Equatable, Sendable {
        public let x0: Int
        public let y0: Int
        public let x1: Int
        public let y1: Int

        public init(x0: Int, y0: Int, x1: Int, y1: Int) {
            self.x0 = x0
            self.y0 = y0
            self.x1 = x1
            self.y1 = y1
        }
    }

    /// One part's state on one tick: the image it draws (nil for the company still), where the image's top left sits on the canvas, in
    /// device pixels, and the window of the image it draws (nil for all of it).
    public struct Step: Equatable, Sendable {
        public let image: String?
        public let dx: Int
        public let dy: Int
        public let window: Window?

        public init(image: String?, dx: Int, dy: Int, window: Window?) {
            self.image = image
            self.dx = dx
            self.dy = dy
            self.window = window
        }

        /// Whether the step is the figure at rest: the still, unmoved and uncropped.
        public var isRest: Bool {
            (image == nil || image == TrackerAvatarEntrance.stillFile) && dx == 0 && dy == 0 && window == nil
        }
    }

    /// A named part and its state on each tick. A nil step hides the part on that tick. The parts draw in name order, between the
    /// effect behind and the effect in front.
    public struct Part: Equatable, Sendable {
        public let name: String
        public let steps: [Step?]

        public init(name: String, steps: [Step?]) {
            self.name = name
            self.steps = steps
        }
    }

    /// The tick the entrance plays at, in seconds: the authored `MotionTick`, divided by the playback speed it was read at.
    public static let playbackTickSeconds: TimeInterval = MotionTick.seconds / TrackerAvatarAnimation.playbackSpeed

    /// How many ticks the entrance plays.
    public let steps: Int
    /// One tick in seconds, at the speed the entrance was read at.
    public let tickSeconds: TimeInterval
    /// Where each effect image's top left sits on the canvas.
    public let origin: Origin
    public let parts: [Part]
    /// The effect image drawn behind the parts on each tick, nil for none.
    public let behind: [String?]
    /// The effect image drawn in front of the parts on each tick, nil for none.
    public let front: [String?]

    /// How long the entrance plays, from its first tick to the end of its last.
    public var seconds: TimeInterval {
        TimeInterval(steps) * tickSeconds
    }

    /// The tick on screen `elapsed` seconds into the entrance, or nil before it starts and once it has ended.
    public func index(at elapsed: TimeInterval) -> Int? {
        guard elapsed >= 0 else {
            return nil
        }
        // A small allowance keeps a tick boundary on its own tick when the division lands a hair below it.
        let index = Int(elapsed / tickSeconds + 1e-9)
        return index < steps ? index : nil
    }

    /// Checks the entrance's shape: every track has one step per tick, each tick's parts and effects agree, the offsets are on the 1 pt
    /// grid (even device pixels), and the entrance ends on the figure at rest, so the idle takes over where it stops. Throws
    /// `TrackerAvatarAnimationError.invalidEntrance` with the first problem.
    public init(
        tick: Double, origin: Origin, parts: [Part], behind: [String?], front: [String?],
        speed: Double = TrackerAvatarAnimation.playbackSpeed
    ) throws {
        guard speed.isFinite, speed > 0 else {
            throw TrackerAvatarAnimationError.invalidSpeed(speed)
        }
        func invalid(_ reason: String) -> TrackerAvatarAnimationError {
            .invalidEntrance(reason)
        }
        guard abs(tick - MotionTick.seconds) < 1e-9 else {
            throw invalid("tick \(tick), not \(MotionTick.seconds)")
        }
        let steps = behind.count
        guard steps >= 1, front.count == steps else {
            throw invalid("effects have \(behind.count) and \(front.count) ticks, not one each")
        }
        guard parts.allSatisfy({ $0.steps.count == steps && !$0.name.isEmpty }) else {
            throw invalid("a part has a track of other than \(steps) ticks")
        }
        guard Set(parts.map(\.name)).count == parts.count else {
            throw invalid("a part is named twice")
        }
        if let figure = parts.first(where: { $0.name == "figure" }) {
            guard let rest = figure.steps.last ?? nil, rest.isRest else {
                throw invalid("the figure does not end at rest")
            }
        }
        guard parts.contains(where: { ($0.steps.last ?? nil) != nil }) else {
            throw invalid("the entrance ends with no part drawn")
        }
        guard (behind.last ?? nil) == nil, (front.last ?? nil) == nil else {
            throw invalid("an effect is still drawn on the last tick")
        }
        for part in parts {
            for step in part.steps.compactMap({ $0 }) {
                guard step.dx % 2 == 0, step.dy % 2 == 0 else {
                    throw invalid("\(part.name) moves by an odd device pixel (\(step.dx), \(step.dy))")
                }
                if let image = step.image {
                    try Self.checkImage(image)
                }
                if let window = step.window, window.x0 < 0 || window.y0 < 0 || window.x1 <= window.x0 || window.y1 <= window.y0 {
                    throw invalid("\(part.name) has an empty window")
                }
            }
        }
        for image in (behind + front).compactMap({ $0 }) {
            try Self.checkImage(image)
        }
        self.steps = steps
        tickSeconds = MotionTick.seconds / speed
        self.origin = origin
        self.parts = parts.sorted { $0.name < $1.name }
        self.behind = behind
        self.front = front
    }

    private static func checkImage(_ name: String) throws {
        guard name.hasSuffix(".png"), !name.contains("/"), name.count > 4 else {
            throw TrackerAvatarAnimationError.invalidEntrance("\(name) is not a PNG in the folder")
        }
    }
}
