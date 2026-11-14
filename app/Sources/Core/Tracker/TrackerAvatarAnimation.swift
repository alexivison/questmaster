import Foundation

/// The layers a pose's art draws in. `character` is the figure himself, `behind` draws under him (summoning's ground circle) and
/// `front` draws over him (calling out's bubble). Each layer plays its own track on its own clock.
public enum TrackerAvatarLayer: String, CaseIterable, Sendable {
    case behind
    case character
    case front
}

/// One step of a track: an art frame number, and how long it shows.
public struct TrackerAvatarStep: Equatable, Sendable {
    public let frame: Int
    public let seconds: TimeInterval

    public init(frame: Int, seconds: TimeInterval) {
        self.frame = frame
        self.seconds = seconds
    }
}

/// One layer's steps in order. A loop cycles them. An enter, a finish or a one-shot plays them once and holds the last frame.
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

/// The tracks a pose plays in one block: a loop, an enter, a finish or a one-shot. Its character track is always there. Its length is its
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

/// One pose's art and timings: where its figure stands, and the blocks it plays. Idle plays none, and draws as layers, unless its file
/// gives it a `loop`, which it then cycles like any steady pose (with no enter or finish of its own). A one-shot
/// plays `once`. The other steady poses cycle `loop`, which an `enter` may open: the enter plays once when the pose comes on screen,
/// then the loop starts from its own first frame. A pose with a loop may also have a `finish`, which plays when it leaves for another
/// pose. A release or a catch may name the frame of its `once` where it strikes.
public struct TrackerAvatarPoseAnimation: Equatable, Sendable {
    /// The row of the lowest boot pixel, and the column of the body's centre, on the pose's canvas.
    public let footRow: Int
    public let bodyColumn: Int
    public let loop: TrackerAvatarBlock?
    public let enter: TrackerAvatarBlock?
    public let finish: TrackerAvatarBlock?
    public let once: TrackerAvatarBlock?
    /// The art frame of the `once` block's character track where the pose strikes, and its move happens (`TrackerAvatarMotion`): the
    /// first step that shows it. Only a release and a catch have one. Nil strikes on the track's second step.
    public let strikeFrame: Int?
    /// Where the shared bubble's bottom centre sits, on the pose's canvas. Only calling out has one; nil draws no bubble.
    public let bubble: TrackerAvatarPixel?
    /// Which way the bubble's tail points; `left` is the art as drawn.
    public let bubbleTail: TrackerAvatarBubbleTail

    public init(
        footRow: Int,
        bodyColumn: Int,
        loop: TrackerAvatarBlock? = nil,
        enter: TrackerAvatarBlock? = nil,
        finish: TrackerAvatarBlock? = nil,
        once: TrackerAvatarBlock? = nil,
        strikeFrame: Int? = nil,
        bubble: TrackerAvatarPixel? = nil,
        bubbleTail: TrackerAvatarBubbleTail = .left
    ) {
        self.footRow = footRow
        self.bodyColumn = bodyColumn
        self.loop = loop
        self.enter = enter
        self.finish = finish
        self.once = once
        self.strikeFrame = strikeFrame
        self.bubble = bubble
        self.bubbleTail = bubbleTail
    }

    /// The step of the `once` character track the pose strikes on when it names its strike frame: the first step that shows it. Nil
    /// when it names none, and the strike is the track's second step.
    var namedStrikeStep: Int? {
        guard let strikeFrame, let once else {
            return nil
        }
        return once.character.steps.firstIndex { $0.frame == strikeFrame }
    }
}

/// Which way the shared bubble's tail points, as `bubble.png` is drawn: `left` (down-left, the default) or `right`, which the app
/// draws mirrored about the anchor's x. A class whose head sits left of its bubble's anchor points the tail at it with `left`.
public enum TrackerAvatarBubbleTail: String, Decodable, Sendable {
    case left
    case right
}

/// An sRGB colour, read from `#rrggbb`.
public struct TrackerAvatarColour: Equatable, Sendable {
    /// The colour as `0xRRGGBB`.
    public let rgb: UInt32

    public init(rgb: UInt32) {
        self.rgb = rgb
    }

    /// Reads `#rrggbb`: a `#` and six hex digits. Nil for any other text.
    public init?(hex: String) {
        let digits = hex.dropFirst()
        guard hex.first == "#", digits.count == 6, digits.allSatisfy(\.isHexDigit), let rgb = UInt32(digits, radix: 16) else {
            return nil
        }
        self.init(rgb: rgb)
    }
}

/// A point on a pose's canvas, in sprite pixels from the top left.
public struct TrackerAvatarPixel: Equatable, Hashable, Sendable {
    public let x: Int
    public let y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

/// One authored breathing image and the exact blink stencil on its canvas.
public struct TrackerAvatarBreathingFrame: Equatable, Sendable {
    public let file: String
    public let seconds: TimeInterval
    public let eyeRow: Int?
    public let eyeColumns: [Int]?
    public let lidPixels: [TrackerAvatarPixel]

    public init(file: String, seconds: TimeInterval, eyeRow: Int?, eyeColumns: [Int]?, lidPixels: [TrackerAvatarPixel]) {
        self.file = file
        self.seconds = seconds
        self.eyeRow = eyeRow
        self.eyeColumns = eyeColumns
        self.lidPixels = lidPixels
    }
}

/// A breathing cycle in its authored order. Repeated filenames are allowed for explicit ping-pong tracks. If the resume image
/// occurs more than once, playback resumes at its first occurrence.
public struct TrackerAvatarBreathing: Equatable, Sendable {
    public let resumeFrame: String
    public let frames: [TrackerAvatarBreathingFrame]

    public init?(resumeFrame: String, frames: [TrackerAvatarBreathingFrame]) {
        let period = frames.reduce(0) { $0 + $1.seconds }
        guard !frames.isEmpty,
              frames.allSatisfy({ $0.seconds.isFinite && $0.seconds > 0 }),
              period.isFinite,
              frames.contains(where: { $0.file == resumeFrame }) else {
            return nil
        }
        self.resumeFrame = resumeFrame
        self.frames = frames
    }

    public var period: TimeInterval {
        frames.reduce(0) { $0 + $1.seconds }
    }

    /// The cycle rotated to begin at `resume_frame`.
    public var framesFromResume: [TrackerAvatarBreathingFrame] {
        guard let start = frames.firstIndex(where: { $0.file == resumeFrame }) else {
            return []
        }
        return Array(frames[start...]) + Array(frames[..<start])
    }

    /// The frame and time until its next change, for elapsed active-idle time.
    public func frame(at elapsed: TimeInterval) -> (frame: TrackerAvatarBreathingFrame, untilNext: TimeInterval)? {
        let playback = framesFromResume
        guard !playback.isEmpty else {
            return nil
        }
        let period = self.period
        var cycleTime = max(0, elapsed).truncatingRemainder(dividingBy: period)
        if period - cycleTime <= max(1e-12, period * 1e-12) {
            cycleTime = 0
        }
        var start: TimeInterval = 0
        for frame in playback {
            let end = start + frame.seconds
            if cycleTime < end {
                return (frame, end - cycleTime)
            }
            start = end
        }
        return (playback[0], playback[0].seconds)
    }
}

/// Idle's still frame, optional authored breathing images and blink settings. No pose pixels are moved in code. An idle may also play
/// an effect over (`front`) or under (`behind`) the figure: a track of `01-idle-front-f<n>` / `01-idle-behind-f<n>` art that loops on its
/// own clock, whatever the figure does. Effect art may stand on a larger canvas than the figure's: `characterAt` is where the figure's
/// canvas top-left falls on the effect canvas (zero when both share one).
public struct TrackerAvatarIdleAnimation: Equatable, Sendable {
    public let blink: Bool
    public let lidColour: TrackerAvatarColour?
    public let stillLidPixels: [TrackerAvatarPixel]
    public let breathing: TrackerAvatarBreathing?
    public let behind: TrackerAvatarTrack?
    public let front: TrackerAvatarTrack?
    public let characterAt: TrackerAvatarPixel

    public init(
        blink: Bool, lidColour: TrackerAvatarColour?, stillLidPixels: [TrackerAvatarPixel], breathing: TrackerAvatarBreathing?,
        behind: TrackerAvatarTrack? = nil, front: TrackerAvatarTrack? = nil, characterAt: TrackerAvatarPixel = TrackerAvatarPixel(x: 0, y: 0)
    ) {
        self.blink = blink
        self.lidColour = lidColour
        self.stillLidPixels = stillLidPixels
        self.breathing = breathing
        self.behind = behind
        self.front = front
        self.characterAt = characterAt
    }

    public func effect(_ layer: TrackerAvatarLayer) -> TrackerAvatarTrack? {
        switch layer {
        case .behind: behind
        case .front: front
        case .character: nil
        }
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

/// How a pose's art plays: idle draws as layers (or cycles a loop, when its file gives it one), a one-shot plays once, and the other
/// poses cycle a loop.
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
    /// A pose's blocks don't match how it plays: an enter or a finish on a pose without a loop (a one-shot, or idle), a loop on a
    /// one-shot, or a one-shot on a steady pose.
    case misplacedBlock(String)
    /// The eye row, eye columns and lid colour must be complete when the legacy shorthand is used.
    case incompleteEyes
    /// Idle or breathing frame lid pixels must be non-empty, unique, and non-negative.
    case invalidLidPixels(String)
    /// A breathing track has an invalid file, duration or resume frame.
    case invalidBreathing(String)
    /// Blinking is enabled, but a still or breathing frame has no lid stencil.
    case missingLidStencil(String)
    /// A pose has a bubble anchor but isn't calling out, the only pose that draws the shared bubble.
    case misplacedBubble(String)
    /// The idle's `character_at` has a negative coordinate.
    case invalidAnchor(String)
    /// A pose has a strike frame but doesn't strike: only a release and a catch move.
    case misplacedStrike(String)
    /// A pose's strike frame isn't a frame of its one-shot's character track.
    case unknownStrikeFrame(String)
    case unknownLayer(String)
    /// A track with no steps, a step that isn't a frame shown for a positive time, or a block with no character track.
    case invalidTrack(String)
    /// The eye columns are two numbers, the first and the last included.
    case invalidEyeColumns
    /// The lid colour is `#rrggbb`.
    case invalidLidColour
}

/// A class's avatar art and timings, read from its `animation.json` (`Resources/Sprites/<class>/`). The file names every pose, and
/// each pose's blocks must fit how the avatar plays it, so a file that would leave the avatar without a timing fails to read.
public struct TrackerAvatarAnimation: Equatable, Sendable {
    /// The only `version` this build reads.
    public static let supportedVersion = 1

    /// Idle's authored breathing and blink data. Nil when `01-idle` is an authored pose loop.
    public let idle: TrackerAvatarIdleAnimation?
    /// The fidgets an idle figure may play, by name. None when `01-idle` has a loop, which plays no fidgets.
    public let fidgets: [TrackerAvatarIdleFidget]
    private let poses: [TrackerAvatarPose: TrackerAvatarPoseAnimation]

    /// Reads and checks a class's `animation.json`.
    public init(data: Data) throws {
        let file = try JSONDecoder().decode(File.self, from: data)
        guard file.version == Self.supportedVersion else {
            throw TrackerAvatarAnimationError.unsupportedVersion(file.version)
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
        // Bard and Barbarian's authored idle loops keep their existing frame-loop behavior and do not read layered-idle metadata.
        if poses[.idle]?.loop != nil {
            idle = nil
            fidgets = []
            return
        }
        idle = try Self.idle(file.idle)
        fidgets = try (file.fidgets ?? [:]).sorted { $0.key < $1.key }.map { name, steps in
            guard let track = TrackerAvatarTrack(steps: steps) else {
                throw TrackerAvatarAnimationError.invalidTrack("fidget \(name)")
            }
            return TrackerAvatarIdleFidget(name: name, track: track)
        }
    }

    /// The pose's art and timings. A file that decodes names every pose.
    public func animation(for pose: TrackerAvatarPose) -> TrackerAvatarPoseAnimation? {
        poses[pose]
    }

    /// How long a one-shot plays: its `once` block's length. Zero for a pose that doesn't play once.
    public func onceSeconds(for pose: TrackerAvatarPose) -> TimeInterval {
        poses[pose]?.once?.seconds ?? 0
    }

    private static func idle(_ file: File.Idle?) throws -> TrackerAvatarIdleAnimation {
        guard let file else {
            return TrackerAvatarIdleAnimation(blink: false, lidColour: nil, stillLidPixels: [], breathing: nil)
        }
        let legacyPixels = try shorthandPixels(row: file.eyeRow, columns: file.eyeColumns, named: "idle")
        let stillPixels = try pixels(file.lidPixels, named: "idle") ?? legacyPixels ?? []
        let needsColour = file.lidPixels != nil || legacyPixels != nil || file.breathing != nil
        let lidColour: TrackerAvatarColour?
        if let lidHex = file.lidColour {
            guard let colour = TrackerAvatarColour(hex: lidHex) else {
                throw TrackerAvatarAnimationError.invalidLidColour
            }
            lidColour = colour
        } else if needsColour {
            throw TrackerAvatarAnimationError.incompleteEyes
        } else {
            lidColour = nil
        }
        let breathing = try breathingTrack(file.breathing, fallback: legacyPixels)
        let hasAnyStencil = breathing?.frames.contains(where: { !$0.lidPixels.isEmpty }) ?? !stillPixels.isEmpty
        let hasCompleteStencil = breathing?.frames.allSatisfy { !$0.lidPixels.isEmpty } ?? !stillPixels.isEmpty
        let blink = file.blink ?? hasAnyStencil
        guard !blink || hasCompleteStencil else {
            throw TrackerAvatarAnimationError.missingLidStencil("idle")
        }
        let behind = try track(file.behind, named: "idle behind")
        let front = try track(file.front, named: "idle front")
        let characterAt = file.characterAt ?? File.Pixel(x: 0, y: 0)
        guard characterAt.x >= 0, characterAt.y >= 0 else {
            throw TrackerAvatarAnimationError.invalidAnchor("idle character_at")
        }
        return TrackerAvatarIdleAnimation(
            blink: blink, lidColour: lidColour, stillLidPixels: stillPixels, breathing: breathing,
            behind: behind, front: front, characterAt: TrackerAvatarPixel(x: characterAt.x, y: characterAt.y)
        )
    }

    private static func breathingTrack(
        _ file: File.Idle.Breathing?, fallback: [TrackerAvatarPixel]?
    ) throws -> TrackerAvatarBreathing? {
        guard let file else {
            return nil
        }
        guard isBreathingFile(file.resumeFrame), !file.frames.isEmpty else {
            throw TrackerAvatarAnimationError.invalidBreathing("resume_frame must name a breathing PNG and frames must not be empty")
        }
        var frames: [TrackerAvatarBreathingFrame] = []
        for frame in file.frames {
            guard isBreathingFile(frame.file), frame.seconds.isFinite, frame.seconds > 0 else {
                throw TrackerAvatarAnimationError.invalidBreathing("\(frame.file) needs a breathing PNG filename and positive finite seconds")
            }
            let shorthand = try shorthandPixels(row: frame.eyeRow, columns: frame.eyeColumns, named: frame.file)
            let stencil = try pixels(frame.lidPixels, named: frame.file) ?? shorthand ?? fallback ?? []
            frames.append(TrackerAvatarBreathingFrame(
                file: frame.file,
                seconds: frame.seconds,
                eyeRow: frame.eyeRow,
                eyeColumns: frame.eyeColumns,
                lidPixels: stencil
            ))
        }
        guard frames.contains(where: { $0.file == file.resumeFrame }) else {
            throw TrackerAvatarAnimationError.invalidBreathing("resume_frame \(file.resumeFrame) is not in frames")
        }
        guard let breathing = TrackerAvatarBreathing(resumeFrame: file.resumeFrame, frames: frames) else {
            throw TrackerAvatarAnimationError.invalidBreathing("resume_frame must name a frame and every frame needs positive finite seconds")
        }
        return breathing
    }

    private static func isBreathingFile(_ file: String) -> Bool {
        file.hasPrefix("01-idle-breath-") && file.dropFirst("01-idle-breath-".count).hasSuffix(".png")
            && file.dropFirst("01-idle-breath-".count).dropLast(".png".count).isEmpty == false
            && !file.contains("/") && !file.contains("\\")
    }

    private static func shorthandPixels(row: Int?, columns: [Int]?, named: String) throws -> [TrackerAvatarPixel]? {
        guard row != nil || columns != nil else {
            return nil
        }
        guard let row, let columns else {
            throw TrackerAvatarAnimationError.incompleteEyes
        }
        guard row >= 0, !columns.isEmpty, columns.allSatisfy({ $0 >= 0 }), Set(columns).count == columns.count else {
            throw TrackerAvatarAnimationError.invalidBreathing("\(named) has invalid eye coordinates")
        }
        if named == "idle" {
            guard columns.count == 2, columns[0] <= columns[1] else {
                throw TrackerAvatarAnimationError.invalidEyeColumns
            }
            return (columns[0]...columns[1]).map { TrackerAvatarPixel(x: $0, y: row) }
        }
        return columns.map { TrackerAvatarPixel(x: $0, y: row) }
    }

    private static func pixels(_ values: [[Int]]?, named: String) throws -> [TrackerAvatarPixel]? {
        guard let values else {
            return nil
        }
        guard !values.isEmpty else {
            throw TrackerAvatarAnimationError.invalidLidPixels(named)
        }
        var seen = Set<TrackerAvatarPixel>()
        var result: [TrackerAvatarPixel] = []
        for pair in values {
            guard pair.count == 2, pair[0] >= 0, pair[1] >= 0 else {
                throw TrackerAvatarAnimationError.invalidLidPixels(named)
            }
            let pixel = TrackerAvatarPixel(x: pair[0], y: pair[1])
            guard seen.insert(pixel).inserted else {
                throw TrackerAvatarAnimationError.invalidLidPixels(named)
            }
            result.append(pixel)
        }
        return result
    }

    private static func poseAnimation(_ pose: File.Pose, named name: String, kind: TrackerAvatarPose) throws -> TrackerAvatarPoseAnimation {
        let loop = try block(pose.loop, named: name)
        let enter = try block(pose.enter, named: name)
        let finish = try block(pose.finish, named: name)
        let once = try block(pose.once, named: name)
        let fitsItsKind: Bool
        switch kind.playKind {
        case .layers: fitsItsKind = once == nil
        case .loop: fitsItsKind = loop != nil && once == nil
        case .oneShot: fitsItsKind = once != nil && loop == nil
        }
        guard fitsItsKind, (enter == nil && finish == nil) || kind.playKind == .loop else {
            throw TrackerAvatarAnimationError.misplacedBlock(name)
        }
        guard pose.bubble == nil || kind == .callingOut else {
            throw TrackerAvatarAnimationError.misplacedBubble(name)
        }
        if let strikeFrame = pose.strikeFrame {
            guard TrackerAvatarMotion.strikePixels(for: kind) != nil, let once else {
                throw TrackerAvatarAnimationError.misplacedStrike(name)
            }
            guard once.character.steps.contains(where: { $0.frame == strikeFrame }) else {
                throw TrackerAvatarAnimationError.unknownStrikeFrame(name)
            }
        }
        return TrackerAvatarPoseAnimation(
            footRow: pose.footRow,
            bodyColumn: pose.bodyColumn,
            loop: loop,
            enter: enter,
            finish: finish,
            once: once,
            strikeFrame: pose.strikeFrame,
            bubble: pose.bubble.map { TrackerAvatarPixel(x: $0.x, y: $0.y) },
            bubbleTail: pose.bubble?.tail ?? .left
        )
    }

    /// A track from its steps; nil when the file gives none. A track that is there must be a good one.
    private static func track(_ steps: [TrackerAvatarStep]?, named name: String) throws -> TrackerAvatarTrack? {
        guard let steps else {
            return nil
        }
        guard let track = TrackerAvatarTrack(steps: steps) else {
            throw TrackerAvatarAnimationError.invalidTrack(name)
        }
        return track
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
        let idle: Idle?
        let fidgets: [String: [TrackerAvatarStep]]?
        let poses: [String: Pose]

        struct Idle: Decodable {
            let eyeRow: Int?
            let eyeColumns: [Int]?
            let lidColour: String?
            let blink: Bool?
            let lidPixels: [[Int]]?
            let breathing: Breathing?
            let behind: [TrackerAvatarStep]?
            let front: [TrackerAvatarStep]?
            let characterAt: Pixel?

            enum CodingKeys: String, CodingKey {
                case characterAt = "character_at"
                case behind, front
                case eyeRow = "eye_row"
                case eyeColumns = "eye_columns"
                case lidColour = "lid_colour"
                case blink, breathing
                case lidPixels = "lid_pixels"
            }

            struct Breathing: Decodable {
                let resumeFrame: String
                let frames: [Frame]

                enum CodingKeys: String, CodingKey {
                    case resumeFrame = "resume_frame"
                    case frames
                }

                struct Frame: Decodable {
                    let file: String
                    let seconds: TimeInterval
                    let eyeRow: Int?
                    let eyeColumns: [Int]?
                    let lidPixels: [[Int]]?

                    enum CodingKeys: String, CodingKey {
                        case file, seconds
                        case eyeRow = "eye_row"
                        case eyeColumns = "eye_columns"
                        case lidPixels = "lid_pixels"
                    }
                }
            }
        }

        struct Pixel: Decodable {
            let x: Int
            let y: Int
        }

        struct Bubble: Decodable {
            let x: Int
            let y: Int
            let tail: TrackerAvatarBubbleTail?
        }

        struct Pose: Decodable {
            let footRow: Int
            let bodyColumn: Int
            let loop: [String: [TrackerAvatarStep]]?
            let enter: [String: [TrackerAvatarStep]]?
            let finish: [String: [TrackerAvatarStep]]?
            let once: [String: [TrackerAvatarStep]]?
            let strikeFrame: Int?
            let bubble: Bubble?

            enum CodingKeys: String, CodingKey {
                case footRow = "foot_row"
                case bodyColumn = "body_column"
                case strikeFrame = "strike_frame"
                case loop, enter, finish, once, bubble
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
