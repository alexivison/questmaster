import Foundation

public struct RuntimeSnapshot {
    public var tracker: TrackerSnapshot
    public var observedLabel: String
    public var sourceLabel: String
    public var tick: Int

    public static func empty(sourceLabel: String) -> RuntimeSnapshot {
        RuntimeSnapshot(
            tracker: TrackerSnapshot(repos: []),
            observedLabel: "",
            sourceLabel: sourceLabel,
            tick: 0
        )
    }

    public var serviceStateMessage: String? {
        let value = observedLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return nil
        }
        let lowercased = value.lowercased()
        guard lowercased.contains("connecting")
            || lowercased.contains("serve not connected")
            || lowercased.contains("serve not configured")
            || lowercased.contains("serve down")
            || lowercased.contains("serve stopped")
            || lowercased.contains("serve protocol incompatible") else {
            return nil
        }
        return value
    }

    public mutating func apply(_ update: RuntimeUpdate) {
        if let tracker = update.tracker {
            self.tracker = tracker
        }
        if let observedLabel = update.observedLabel {
            self.observedLabel = observedLabel
        }
        tick += 1
    }
}

public struct RuntimeUpdate: Decodable {
    public var tracker: TrackerSnapshot?
    public var observedLabel: String?

    private enum CodingKeys: String, CodingKey {
        case type
        case data
        case tracker
        case observed_at
    }

    public init(
        tracker: TrackerSnapshot? = nil,
        observedLabel: String? = nil
    ) {
        self.tracker = tracker
        self.observedLabel = observedLabel
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decodeIfPresent(String.self, forKey: .type)

        tracker = try container.decodeIfPresent(TrackerSnapshot.self, forKey: .tracker)
        observedLabel = try container.decodeIfPresent(String.self, forKey: .observed_at)

        guard container.contains(.data) else {
            return
        }

        switch type {
        case "tracker":
            tracker = try container.decodeIfPresent(TrackerSnapshot.self, forKey: .data) ?? tracker
        default:
            if let nested = try container.decodeIfPresent(RuntimeUpdate.self, forKey: .data) {
                tracker = tracker ?? nested.tracker
                observedLabel = observedLabel ?? nested.observedLabel
            }
        }
    }
}

public extension RuntimeUpdate {
    static func serveUnavailable(_ message: String) -> RuntimeUpdate {
        RuntimeUpdate(
            tracker: TrackerSnapshot(repos: []),
            observedLabel: message
        )
    }
}
