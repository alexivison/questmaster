import Foundation

/// The layers a pose's art draws in. `character` is the figure himself, `behind` draws under him (summoning's ground circle) and
/// `front` draws over him (calling out's bubble). Each layer plays its own track on its own clock.
public enum TrackerAvatarLayer: String, CaseIterable, Sendable {
    case behind
    case character
    case front
}

/// One step of a track: an art frame (`<pose>-f<n>` for the character, its layer's own name for an effect), and how long it shows.
public struct TrackerAvatarStep: Equatable, Sendable {
    public let frame: Int
    public let seconds: TimeInterval

    public init(frame: Int, seconds: TimeInterval) {
        self.frame = frame
        self.seconds = seconds
    }
}

/// One layer's steps in order. A loop cycles them. A finish or a one-shot plays them once and holds the last frame.
public struct TrackerAvatarTrack: Equatable, Sendable {
    public let steps: [TrackerAvatarStep]

    /// Nil when there are no steps, or a step is not a frame (1 or more) shown for a positive time.
    public init?(steps: [TrackerAvatarStep]) {
        guard !steps.isEmpty, steps.allSatisfy({ $0.frame >= 1 && $0.seconds > 0 }) else {
            return nil
        }
        self.steps = steps
    }

    /// How long the track runs once through.
    public var seconds: TimeInterval {
        steps.reduce(0) { $0 + $1.seconds }
    }

    /// When each step starts, from the track's start.
    public var starts: [TimeInterval] {
        var starts: [TimeInterval] = []
        var start: TimeInterval = 0
        for step in steps {
            starts.append(start)
            start += step.seconds
        }
        return starts
    }

    /// The frame on screen `elapsed` seconds into the track. A looping track cycles. Any other track holds its last frame once its
    /// steps have run out.
    public func frame(at elapsed: TimeInterval, looping: Bool) -> Int {
        let time = looping ? elapsed.truncatingRemainder(dividingBy: seconds) : elapsed
        let index = starts.lastIndex { $0 <= time } ?? 0
        return steps[index].frame
    }
}

/// The tracks a pose plays in one block: a loop, a finish or a one-shot. Its character track is always there. Its length is its
/// longest track, so a block with an effect that runs longer than the figure keeps the figure on its last frame.
public struct TrackerAvatarBlock: Equatable, Sendable {
    public let character: TrackerAvatarTrack
    public let behind: TrackerAvatarTrack?
    public let front: TrackerAvatarTrack?

    public init(character: TrackerAvatarTrack, behind: TrackerAvatarTrack? = nil, front: TrackerAvatarTrack? = nil) {
        self.character = character
        self.behind = behind
        self.front = front
    }

    public func track(for layer: TrackerAvatarLayer) -> TrackerAvatarTrack? {
        switch layer {
        case .behind: behind
        case .character: character
        case .front: front
        }
    }

    /// How long the block lasts: its longest track.
    public var seconds: TimeInterval {
        TrackerAvatarLayer.allCases.compactMap { track(for: $0)?.seconds }.max() ?? 0
    }

    /// When any track changes frame, from the block's start, in order. The start itself is left out.
    public var changes: [TimeInterval] {
        let starts = TrackerAvatarLayer.allCases.compactMap { track(for: $0)?.starts }.flatMap { $0 }
        return Array(Set(starts)).filter { $0 > 0 }.sorted()
    }
}

/// One pose's art and timings: where its figure stands, and the blocks it plays. Idle plays none, and draws as layers. A one-shot
/// plays `once`. The other steady poses cycle `loop`, and a cast also has a `finish` for when it leaves for another pose.
public struct TrackerAvatarPoseAnimation: Equatable, Sendable {
    /// The row of the lowest boot pixel, and the column of the body's centre, on the pose's canvas.
    public let footRow: Int
    public let bodyColumn: Int
    public let loop: TrackerAvatarBlock?
    public let finish: TrackerAvatarBlock?
    public let once: TrackerAvatarBlock?

    public init(
        footRow: Int,
        bodyColumn: Int,
        loop: TrackerAvatarBlock? = nil,
        finish: TrackerAvatarBlock? = nil,
        once: TrackerAvatarBlock? = nil
    ) {
        self.footRow = footRow
        self.bodyColumn = bodyColumn
        self.loop = loop
        self.finish = finish
        self.once = once
    }
}

/// Idle draws as layers: the legs and cloak hold still while the figure above them breathes, and the eyelids cover the eyes.
public struct TrackerAvatarIdle: Equatable, Sendable {
    /// The bottom rows, which stay still while the figure above breathes.
    public let legRows: Int
    /// The row the lids cover while a blink shows.
    public let eyeRow: Int
    /// The columns the lids cover, the first and the last included.
    public let eyeColumns: ClosedRange<Int>

    public init(legRows: Int, eyeRow: Int, eyeColumns: ClosedRange<Int>) {
        self.legRows = legRows
        self.eyeRow = eyeRow
        self.eyeColumns = eyeColumns
    }
}

/// A point on a pose's canvas, in sprite pixels from the top left.
public struct TrackerAvatarPixel: Equatable, Sendable {
    public let x: Int
    public let y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

/// An idle fidget: a track of idle frames, played in place. Its name is its key in `animation.json`.
public struct TrackerAvatarIdleFidget: Equatable, Sendable {
    public let name: String
    public let track: TrackerAvatarTrack

    public init(name: String, track: TrackerAvatarTrack) {
        self.name = name
        self.track = track
    }

    /// The idle frames the fidget plays, in order.
    public var frames: [Int] {
        track.steps.map(\.frame)
    }
}

/// How a pose's art plays: idle draws as layers, a one-shot plays once, and the other poses cycle a loop.
public enum TrackerAvatarPlayKind: Equatable, Sendable {
    case layers
    case loop
    case oneShot
}

/// Why a class's `animation.json` can't drive the avatar. Any of these shows no avatar for the class.
public enum TrackerAvatarAnimationError: Error, Equatable {
    case unsupportedVersion(Int)
    case unknownPose(String)
    case missingPose(String)
    /// A pose's blocks don't match how it plays, or it has a finish but isn't a cast.
    case misplacedBlock(String)
    case unknownLayer(String)
    /// A track with no steps, a step that isn't a frame shown for a positive time, or a block with no character track.
    case invalidTrack(String)
    /// The eye columns are two numbers, the first and the last included.
    case invalidEyeColumns
}

/// A class's avatar art and timings, read from its `animation.json` (`Resources/Sprites/<class>/`). The file names every pose, and
/// each pose's blocks must fit how the avatar plays it, so a file that would leave the avatar without a timing fails to read.
public struct TrackerAvatarAnimation: Equatable, Sendable {
    /// The only `version` this build reads.
    public static let supportedVersion = 1

    public let idle: TrackerAvatarIdle
    /// The point a release's spell leaves the caster's hand from, on the release pose's canvas.
    public let releaseHand: TrackerAvatarPixel
    /// The fidgets an idle figure may play, by name.
    public let fidgets: [TrackerAvatarIdleFidget]
    private let poses: [TrackerAvatarPose: TrackerAvatarPoseAnimation]

    /// Reads and checks a class's `animation.json`.
    public init(data: Data) throws {
        let file = try JSONDecoder().decode(File.self, from: data)
        guard file.version == Self.supportedVersion else {
            throw TrackerAvatarAnimationError.unsupportedVersion(file.version)
        }
        idle = try Self.idle(file.idle)
        releaseHand = TrackerAvatarPixel(x: file.releaseHand.x, y: file.releaseHand.y)
        fidgets = try file.fidgets.sorted { $0.key < $1.key }.map { name, steps in
            guard let track = TrackerAvatarTrack(steps: steps) else {
                throw TrackerAvatarAnimationError.invalidTrack("fidget \(name)")
            }
            return TrackerAvatarIdleFidget(name: name, track: track)
        }
        var poses: [TrackerAvatarPose: TrackerAvatarPoseAnimation] = [:]
        for (name, pose) in file.poses {
            guard let kind = TrackerAvatarPose.allCases.first(where: { $0.resourceName == name }) else {
                throw TrackerAvatarAnimationError.unknownPose(name)
            }
            poses[kind] = try Self.poseAnimation(pose, named: name, kind: kind)
        }
        for pose in TrackerAvatarPose.allCases where poses[pose] == nil {
            throw TrackerAvatarAnimationError.missingPose(pose.resourceName)
        }
        self.poses = poses
    }

    /// The pose's art and timings. A file that decodes names every pose.
    public func animation(for pose: TrackerAvatarPose) -> TrackerAvatarPoseAnimation? {
        poses[pose]
    }

    private static func idle(_ file: File.Idle) throws -> TrackerAvatarIdle {
        guard let first = file.eyeColumns.first, file.eyeColumns.count == 2, let last = file.eyeColumns.last, first <= last else {
            throw TrackerAvatarAnimationError.invalidEyeColumns
        }
        return TrackerAvatarIdle(legRows: file.legRows, eyeRow: file.eyeRow, eyeColumns: first...last)
    }

    private static func poseAnimation(_ pose: File.Pose, named name: String, kind: TrackerAvatarPose) throws -> TrackerAvatarPoseAnimation {
        let loop = try block(pose.loop, named: name)
        let finish = try block(pose.finish, named: name)
        let once = try block(pose.once, named: name)
        let fitsItsKind: Bool
        switch kind.playKind {
        case .layers: fitsItsKind = loop == nil && once == nil
        case .loop: fitsItsKind = loop != nil && once == nil
        case .oneShot: fitsItsKind = once != nil && loop == nil
        }
        guard fitsItsKind, finish == nil || kind.isCast else {
            throw TrackerAvatarAnimationError.misplacedBlock(name)
        }
        return TrackerAvatarPoseAnimation(
            footRow: pose.footRow,
            bodyColumn: pose.bodyColumn,
            loop: loop,
            finish: finish,
            once: once
        )
    }

    private static func block(_ tracks: [String: [TrackerAvatarStep]]?, named name: String) throws -> TrackerAvatarBlock? {
        guard let tracks else {
            return nil
        }
        var layers: [TrackerAvatarLayer: TrackerAvatarTrack] = [:]
        for (key, steps) in tracks {
            guard let layer = TrackerAvatarLayer(rawValue: key) else {
                throw TrackerAvatarAnimationError.unknownLayer(key)
            }
            guard let track = TrackerAvatarTrack(steps: steps) else {
                throw TrackerAvatarAnimationError.invalidTrack("\(name) \(key)")
            }
            layers[layer] = track
        }
        guard let character = layers[.character] else {
            throw TrackerAvatarAnimationError.invalidTrack("\(name) has no character track")
        }
        return TrackerAvatarBlock(character: character, behind: layers[.behind], front: layers[.front])
    }

    /// The file as JSON spells it. Its names and shapes are checked in `init(data:)`.
    private struct File: Decodable {
        let version: Int
        let idle: Idle
        let releaseHand: Pixel
        let fidgets: [String: [TrackerAvatarStep]]
        let poses: [String: Pose]

        enum CodingKeys: String, CodingKey {
            case version, idle, fidgets, poses
            case releaseHand = "release_hand"
        }

        struct Idle: Decodable {
            let legRows: Int
            let eyeRow: Int
            let eyeColumns: [Int]

            enum CodingKeys: String, CodingKey {
                case legRows = "leg_rows"
                case eyeRow = "eye_row"
                case eyeColumns = "eye_columns"
            }
        }

        struct Pixel: Decodable {
            let x: Int
            let y: Int
        }

        struct Pose: Decodable {
            let footRow: Int
            let bodyColumn: Int
            let loop: [String: [TrackerAvatarStep]]?
            let finish: [String: [TrackerAvatarStep]]?
            let once: [String: [TrackerAvatarStep]]?

            enum CodingKeys: String, CodingKey {
                case footRow = "foot_row"
                case bodyColumn = "body_column"
                case loop, finish, once
            }
        }
    }
}

/// A step reads as `[frame, seconds]`, two values and no more.
extension TrackerAvatarStep: Decodable {
    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let frame = try container.decode(Int.self)
        let seconds = try container.decode(TimeInterval.self)
        guard container.isAtEnd else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "a step is [frame, seconds]")
        }
        self.init(frame: frame, seconds: seconds)
    }
}

/// The class avatars the app has art for, by class id (the folder in `Resources/Sprites`). Only a master whose class has one shows
/// an avatar. A worker, a shell and a session with no known class show none.
public struct TrackerAvatarCatalog: Sendable {
    private let animations: [String: TrackerAvatarAnimation]

    public init(animations: [String: TrackerAvatarAnimation]) {
        self.animations = animations
    }

    /// The class id of a master whose class has art; nil for any other session.
    public func classID(for session: TrackerSession?) -> String? {
        guard let session, case .master(let sessionClass?)? = SessionPortrait(session: session),
              animations[sessionClass.rawValue] != nil else {
            return nil
        }
        return sessionClass.rawValue
    }

    /// The art of a master's class, when the class has any.
    public func animation(for session: TrackerSession?) -> TrackerAvatarAnimation? {
        classID(for: session).flatMap { animations[$0] }
    }
}
