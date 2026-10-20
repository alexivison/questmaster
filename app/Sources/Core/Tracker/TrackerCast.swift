import Foundation

/// The tool a session is running, from the tracker payload's `cast`: the raw tool name (what the chat's action entry
/// carries), when it started, and how long that agent's tool usually runs (0 when unknown).
public struct TrackerCast: Decodable, Equatable {
    public var tool: String
    public var startedAt: Date
    public var typicalMS: Int

    public init(tool: String, startedAt: Date, typicalMS: Int) {
        self.tool = tool
        self.startedAt = startedAt
        self.typicalMS = typicalMS
    }

    private enum CodingKeys: String, CodingKey {
        case tool
        case started_at
        case typical_ms
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tool = try container.decode(String.self, forKey: .tool)
        let started = try container.decode(String.self, forKey: .started_at)
        guard let startedAt = TrackerSession.parseInstant(started) else {
            throw DecodingError.dataCorruptedError(forKey: .started_at, in: container, debugDescription: "cast started_at is not RFC3339: \(started)")
        }
        self.startedAt = startedAt
        typicalMS = try container.decodeIfPresent(Int.self, forKey: .typical_ms) ?? 0
    }

    /// The learned duration in seconds, or nil when the tool has none and the bar shimmers instead of filling.
    public var typicalDuration: TimeInterval? {
        typicalMS > 0 ? TimeInterval(typicalMS) / 1000 : nil
    }

    /// The bar's label: the chat's own text for a tool call, `[Bash]`.
    public var label: String {
        WorkerChatLineBuilder.callLabel(name: tool)
    }
}

/// How a cast bar fills: linearly to 90% at the tool's typical duration, then creeping toward 95% and holding there,
/// short of full, until the tool ends.
public enum TrackerCastFill {
    public static let fillAtTypical = 0.9
    public static let holdShortOfFull = 0.95
    /// After the typical duration the creep is sampled over this many typical durations, by when it has all but
    /// reached the hold.
    public static let creepSpan = 4.0
    public static let creepSamples = 12

    public static func fraction(elapsed: TimeInterval, typical: TimeInterval) -> Double {
        let elapsed = max(0, elapsed)
        guard elapsed >= typical else { return fillAtTypical * elapsed / typical }
        return holdShortOfFull - (holdShortOfFull - fillAtTypical) * exp(-(elapsed - typical) / typical)
    }

    /// The fill's path from `elapsed` on, as (seconds from now, fraction) pairs for a linear keyframe animation: the
    /// current fraction, the 90% mark at the typical duration if it is still ahead, then samples of the creep. The last
    /// pair is where the bar holds.
    public static func keyframes(elapsed: TimeInterval, typical: TimeInterval) -> [(offset: TimeInterval, fraction: Double)] {
        let elapsed = max(0, elapsed)
        var frames = [(offset: 0.0, fraction: fraction(elapsed: elapsed, typical: typical))]
        if elapsed < typical {
            frames.append((typical - elapsed, fillAtTypical))
        }
        let creepStart = max(elapsed, typical)
        let creepEnd = typical * (1 + creepSpan)
        guard creepEnd > creepStart else { return frames }
        for sample in 1...creepSamples {
            let at = creepStart + (creepEnd - creepStart) * Double(sample) / Double(creepSamples)
            frames.append((at - elapsed, fraction(elapsed: at, typical: typical)))
        }
        return frames
    }
}

/// What a plate's cast row shows as casts come and go. A cast opens the row; when it ends the row finishes (the bar
/// fills, flashes and fades) and then hides. A new cast replaces the current one at once, so the row stays open.
public enum TrackerCastPhase: Equatable {
    case hidden
    case casting(TrackerCast)
    case finishing(TrackerCast)

    public static let flashDuration: TimeInterval = 0.3
    public static let barFadeDuration: TimeInterval = 0.15
    /// How long the row takes to open or close: the tracker's expand/collapse animation, `.snappy(duration: 0.22)`.
    public static let rowDuration: TimeInterval = 0.22

    /// The phase after the payload reports `cast` (nil when no tool runs).
    public func next(cast: TrackerCast?) -> TrackerCastPhase {
        if let cast { return .casting(cast) }
        if case .casting(let ended) = self { return .finishing(ended) }
        return self
    }

    /// The cast the row shows, while it shows one.
    public var cast: TrackerCast? {
        switch self {
        case .hidden: nil
        case .casting(let cast), .finishing(let cast): cast
        }
    }

    public var isOpen: Bool { self != .hidden }
    public var isFinishing: Bool {
        if case .finishing = self { return true }
        return false
    }
}
