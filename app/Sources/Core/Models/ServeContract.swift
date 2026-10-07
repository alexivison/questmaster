import Foundation

public enum ServeContract {
    public static let protocolVersion = 1

    private static let decoder = JSONDecoder()

    public static func update(fromLine line: Data) throws -> RuntimeUpdate? {
        guard !line.isEmpty else {
            return nil
        }
        return try decoder.decode(ServeEnvelope.self, from: line).update
    }
}

public struct WorkerFeedPayload: Decodable {
    public var entries: [WorkerFeedEntry]
    public var cursors: [String: WorkerFeedCursor]
    public var hasMore: [String: Bool]
    public var errors: [String: String]?

    enum CodingKeys: String, CodingKey {
        case entries, cursors, errors
        case hasMore = "has_more"
    }
}

public struct WorkerFeedEntry: Decodable {
    public var timestamp: String
    public var workerID: String
    public var workerTitle: String?
    public var kind: String
    public var text: String
    public var summary: String?

    enum CodingKeys: String, CodingKey {
        case timestamp, kind, text, summary
        case workerID = "worker_id"
        case workerTitle = "worker_title"
    }
}

public struct WorkerFeedCursor: Decodable {
    public var offset: Int64
    public var fileID: String?

    enum CodingKeys: String, CodingKey {
        case offset
        case fileID = "file_id"
    }
}

private struct ServeEnvelope: Decodable {
    var update: RuntimeUpdate?

    private enum CodingKeys: String, CodingKey {
        case protocol_version
        case type
        case ok
        case topic
        case data
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let protocolVersion = try container.decodeIfPresent(Int.self, forKey: .protocol_version) else {
            throw ServeClientError.protocolError("serve protocol incompatible: missing protocol_version")
        }
        guard protocolVersion == ServeContract.protocolVersion else {
            throw ServeClientError.protocolError("serve protocol incompatible: expected protocol_version \(ServeContract.protocolVersion), got \(protocolVersion)")
        }
        let type = try container.decodeIfPresent(String.self, forKey: .type)
        if type == "response", try container.decodeIfPresent(Bool.self, forKey: .ok) == false {
            let message = try container.decodeIfPresent(String.self, forKey: .error) ?? "unknown serve error"
            throw ServeClientError.protocolError(message)
        }
        guard let topic = try container.decodeIfPresent(String.self, forKey: .topic),
              container.contains(.data) else {
            update = nil
            return
        }

        let payload = try container.superDecoder(forKey: .data)
        switch topic {
        case "tracker":
            let observed = try ObservedPayload(from: payload).observedLabel
            update = RuntimeUpdate(tracker: try TrackerSnapshot(from: payload), observedLabel: observed)
        default:
            update = nil
        }
    }
}

private struct ObservedPayload: Decodable {
    var observedLabel: String

    private enum CodingKeys: String, CodingKey {
        case observed_at
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        observedLabel = try container.decodeIfPresent(String.self, forKey: .observed_at) ?? ""
    }
}

public enum ServeClientError: LocalizedError {
    case connect(String)
    case protocolError(String)
    case write(String)

    public var errorDescription: String? {
        switch self {
        case .connect(let message), .protocolError(let message), .write(let message):
            return message
        }
    }

    public var isProtocolVersionMismatch: Bool {
        guard case .protocolError(let message) = self else {
            return false
        }
        return message.contains("protocol_version")
    }
}
