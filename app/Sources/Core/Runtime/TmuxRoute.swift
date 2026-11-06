import Foundation

public enum TmuxSurfaceDecision: Equatable, Sendable {
    case reuseClient
    case newSurface
}

public struct TmuxRoute: Decodable, Equatable, Sendable {
    public let sessionID: String
    public let label: String
    public let configFiles: [String]
    public let live: Bool
    public let createdUnix: Int64

    public init(sessionID: String, label: String, configFiles: [String], live: Bool, createdUnix: Int64) throws {
        guard !sessionID.isEmpty else { throw TmuxRouteError.invalidSessionID }
        // The backend permits underscores in a development label.
        guard (1...32).contains(label.utf8.count),
              label.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw TmuxRouteError.invalidLabel(label)
        }
        guard configFiles.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }) else {
            throw TmuxRouteError.invalidConfigPath
        }
        self.sessionID = sessionID
        self.label = label
        self.configFiles = configFiles
        self.live = live
        self.createdUnix = createdUnix
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case label = "server"
        case configFiles = "config_files"
        case live
        case createdUnix = "created_unix"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionID: values.decode(String.self, forKey: .sessionID),
            label: values.decode(String.self, forKey: .label),
            configFiles: values.decode([String].self, forKey: .configFiles),
            live: values.decode(Bool.self, forKey: .live),
            createdUnix: values.decode(Int64.self, forKey: .createdUnix)
        )
    }

    public func arguments(for command: [String]) -> [String] {
        ["-L", label] + configFiles.flatMap { ["-f", $0] } + command
    }

    public static func surfaceDecision(
        attachedLabel: String?, targetLabel: String,
        clientAttached: Bool, sessionReappeared: Bool
    ) -> TmuxSurfaceDecision {
        attachedLabel == targetLabel && clientAttached && !sessionReappeared ? .reuseClient : .newSurface
    }

    public static func startupChoice(preferred: String?, routes: [TmuxRoute]) -> TmuxRoute? {
        let live = routes.filter(\.live)
        if let preferred, let route = live.first(where: { $0.sessionID == preferred }) {
            return route
        }
        return live.max { $0.createdUnix < $1.createdUnix }
    }

    public static func decodeResponse(_ data: Data) throws -> [TmuxRoute] {
        let envelope = try JSONDecoder().decode(Response.self, from: data)
        try ServeContract.requireProtocolVersion(envelope.protocolVersion)
        guard envelope.type == "response", envelope.topic == "tmux.routes", envelope.ok else {
            throw TmuxRouteError.invalidResponse
        }
        return envelope.data
    }

    private struct Response: Decodable {
        let protocolVersion: Int
        let type: String
        let topic: String
        let ok: Bool
        let data: [TmuxRoute]

        enum CodingKeys: String, CodingKey {
            case protocolVersion = "protocol_version"
            case type, topic, ok, data
        }
    }
}

public enum TmuxRouteError: LocalizedError {
    case invalidSessionID
    case invalidLabel(String)
    case invalidConfigPath
    case invalidResponse
    case missingSession(String)
    case unsupportedDaemon

    public var errorDescription: String? {
        switch self {
        case .invalidSessionID: "tmux route has no session id"
        case .invalidLabel(let label): "invalid tmux server label: \(label)"
        case .invalidConfigPath: "tmux route has a non-absolute config path"
        case .invalidResponse: "invalid tmux.routes response"
        case .missingSession(let sessionID): "Session \(sessionID) is unavailable"
        case .unsupportedDaemon: "Cannot attach: this daemon does not support tmux.routes. Update the backend."
        }
    }
}
