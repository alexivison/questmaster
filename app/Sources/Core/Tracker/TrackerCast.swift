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

/// How a cast bar fills: linearly to full at the tool's typical duration. A tool that runs past it holds the bar full,
/// pulsing, until it ends.
public enum TrackerCastFill {
    /// The full bar's pulse while a tool overruns: one bright-and-back cycle.
    public static let pulsePeriod: TimeInterval = 1.2

    public static func fraction(elapsed: TimeInterval, typical: TimeInterval) -> Double {
        min(1, max(0, elapsed) / typical)
    }

    /// How long until the bar is full; 0 once the tool has run its typical duration, when it pulses instead.
    public static func timeToFull(elapsed: TimeInterval, typical: TimeInterval) -> TimeInterval {
        max(0, typical - max(0, elapsed))
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

    /// The phase after the payload reports `cast` (nil when no tool runs) for a session in `status`. A blocked session
    /// or one that needs input already says so on its ring, so its row hides the cast, with no finish flash, until the
    /// status leaves; a cast still running then shows again.
    public func next(cast: TrackerCast?, status: TrackerStatusKind) -> TrackerCastPhase {
        if status == .blocked || status == .needsInput { return .hidden }
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

/// What a portrait's ring shows. A working session's ring mirrors its cast bar: it fills around the disc toward the
/// tool's learned duration, or spins while the session works with no tool or one with no learned duration. Blocked,
/// needs-input and error sessions show a still ring in their status colour; the rest show none.
public enum TrackerPortraitRing: Equatable {
    case none
    case steady
    case spinning(TrackerCast?)
    case filling(TrackerCast)

    public static func ring(status: TrackerStatusKind, cast: TrackerCast?) -> TrackerPortraitRing {
        switch status {
        case .working:
            guard let cast, cast.typicalDuration != nil else { return .spinning(cast) }
            return .filling(cast)
        case .blocked, .needsInput, .error:
            return .steady
        case .done, .idle, .stopped:
            return .none
        }
    }

    /// Whether the ring is a working one: filling or spinning. Leaving it for no ring plays the ring's exit; leaving it
    /// for a steady ring crossfades.
    public var isWorking: Bool {
        switch self {
        case .spinning, .filling: true
        case .none, .steady: false
        }
    }

    /// The cast the ring is showing, if any. When it goes or changes, the ring flashes the finish like the cast bar.
    public var cast: TrackerCast? {
        switch self {
        case .spinning(let cast): cast
        case .filling(let cast): cast
        case .none, .steady: nil
        }
    }
}
