import Foundation

public struct RuntimeSnapshot {
    public var tracker: TrackerSnapshot
    public var connection: ConnectionState
    public var observedLabel: String
    public var sourceLabel: String
    public var tick: Int

    /// A snapshot starts connected: a store fed directly (a preview, a test) has no backend to wait for. The app's
    /// runtime connection reports `.connecting` as it starts.
    public static func empty(sourceLabel: String) -> RuntimeSnapshot {
        RuntimeSnapshot(
            tracker: TrackerSnapshot(repos: []),
            connection: .connected,
            observedLabel: "",
            sourceLabel: sourceLabel,
            tick: 0
        )
    }

    /// Merges the update, returning false when it changed nothing — callers
    /// use that to skip observer notification entirely. A connection state alone leaves the tracker as it was, so a
    /// reconnect keeps the last one, except an incompatible backend's, which empties it: nothing it sent applies.
    @discardableResult
    public mutating func apply(_ update: RuntimeUpdate) -> Bool {
        var changed = false
        if let connection = update.connection, connection != self.connection {
            self.connection = connection
            changed = true
        }
        var tracker = update.tracker
        if case .incompatible = update.connection {
            tracker = TrackerSnapshot(repos: [])
        }
        if let tracker, tracker != self.tracker {
            self.tracker = tracker
            changed = true
        }
        if let observedLabel = update.observedLabel, observedLabel != self.observedLabel {
            self.observedLabel = observedLabel
            changed = true
        }
        if changed {
            tick += 1
        }
        return changed
    }
}

public struct RuntimeUpdate: Decodable {
    public var tracker: TrackerSnapshot?
    public var observedLabel: String?
    /// Set by the serve client, never decoded: the wire carries no connection state.
    public var connection: ConnectionState?

    private enum CodingKeys: String, CodingKey {
        case type
        case data
        case tracker
        case observed_at
    }

    public init(
        tracker: TrackerSnapshot? = nil,
        observedLabel: String? = nil,
        connection: ConnectionState? = nil
    ) {
        self.tracker = tracker
        self.observedLabel = observedLabel
        self.connection = connection
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
