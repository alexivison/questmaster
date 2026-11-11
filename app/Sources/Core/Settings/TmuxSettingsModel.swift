import Foundation

public struct TmuxConfigStatus: Decodable, Equatable {
    public var config: String
    public var enforced: String
    public var effectiveLabel: String
    public var running: Bool
    public var startedUnix: Int64
    public var sessions: Int
    public var editedSinceStart: Bool
    public var enforcedPending: Bool
    public var templateVersion: Int
    public var builtinTemplateVersion: Int

    public init(config: String, enforced: String, effectiveLabel: String, running: Bool, startedUnix: Int64, sessions: Int,
                editedSinceStart: Bool, enforcedPending: Bool, templateVersion: Int, builtinTemplateVersion: Int) {
        self.config = config
        self.enforced = enforced
        self.effectiveLabel = effectiveLabel
        self.running = running
        self.startedUnix = startedUnix
        self.sessions = sessions
        self.editedSinceStart = editedSinceStart
        self.enforcedPending = enforcedPending
        self.templateVersion = templateVersion
        self.builtinTemplateVersion = builtinTemplateVersion
    }

    enum CodingKeys: String, CodingKey {
        case config, enforced, running, sessions
        case effectiveLabel = "effective_label"
        case startedUnix = "started_unix"
        case editedSinceStart = "edited_since_start"
        case enforcedPending = "enforced_pending"
        case templateVersion = "template_version"
        case builtinTemplateVersion = "builtin_template_version"
    }

    public static func decodeResponse(_ data: Data) throws -> Self {
        try TmuxConfigResponse<Self>.decode(data, topic: "tmux.config")
    }
}

public struct TmuxConfigCheck: Decodable, Equatable {
    public let ok: Bool
    public let errors: [String]
    public let effectiveLabel: String

    enum CodingKeys: String, CodingKey {
        case ok, errors
        case effectiveLabel = "effective_label"
    }

    public static func decodeResponse(_ data: Data) throws -> Self {
        try TmuxConfigResponse<Self>.decode(data, topic: "tmux.config.check")
    }
}

public struct TmuxConfigReload: Decodable {
    public let running: Bool
    public let errors: [String]

    public static func decodeResponse(_ data: Data) throws -> Self {
        try TmuxConfigResponse<Self>.decode(data, topic: "tmux.config.reload")
    }
}

public struct TmuxServerRestart: Decodable {
    public let restarted: Bool
    public let refused: Bool
    public let sessions: Int

    public static func decodeResponse(_ data: Data) throws -> Self {
        try TmuxConfigResponse<Self>.decode(data, topic: "tmux.server.restart")
    }
}

public struct TmuxSettingsModel {
    public let status: TmuxConfigStatus
    public private(set) var focusedActionIndex = 0

    public init(status: TmuxConfigStatus) {
        self.status = status
    }

    public var canReload: Bool { status.running }
    public var canRestart: Bool { status.running && status.sessions == 0 }
    public var focusedAction: TmuxSettingsAction { TmuxSettingsAction.allCases[focusedActionIndex] }
    public func canPerform(_ action: TmuxSettingsAction) -> Bool {
        switch action {
        case .reload: canReload
        case .restart: canRestart
        default: true
        }
    }

    public mutating func moveFocus(_ delta: Int) {
        let count = TmuxSettingsAction.allCases.count
        focusedActionIndex = (focusedActionIndex + delta + count) % count
    }

    public mutating func focus(_ action: TmuxSettingsAction) {
        focusedActionIndex = TmuxSettingsAction.allCases.firstIndex(of: action) ?? 0
    }
    public var showsEditedSinceStart: Bool { status.editedSinceStart }
    public var showsEnforcedPending: Bool { status.enforcedPending }
    public var showsNewerTemplate: Bool { status.builtinTemplateVersion > status.templateVersion }

    public var serverCaption: String {
        guard status.running else { return "Not running: the next session start reads the file" }
        let started = Date(timeIntervalSince1970: TimeInterval(status.startedUnix))
            .formatted(date: .abbreviated, time: .shortened)
        let noun = status.sessions == 1 ? "session" : "sessions"
        return "Running since \(started), \(status.sessions) \(noun)"
    }

    public var reloadCaption: String {
        guard canReload else { return "The server is not running; the next session start reads the file." }
        return "Applies changed values and new bindings now; removed lines and new-pane options need a restart."
    }

    public var restartCaption: String {
        guard status.running else { return "The server is not running." }
        guard status.sessions > 0 else { return "Restarts the empty server with the current config." }
        let noun = status.sessions == 1 ? "session" : "sessions"
        return "Restart is available when the \(status.sessions) \(noun) \(status.sessions == 1 ? "ends" : "end")."
    }
}

public enum TmuxSettingsAction: CaseIterable {
    case openEditor, reveal, check, reload, restart
}

private struct TmuxConfigResponse<Payload: Decodable>: Decodable {
    let protocolVersion: Int
    let type: String
    let ok: Bool
    let topic: String
    let data: Payload

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case type, ok, topic, data
    }

    static func decode(_ raw: Data, topic: String) throws -> Payload {
        let response = try JSONDecoder().decode(Self.self, from: raw)
        try ServeContract.requireProtocolVersion(response.protocolVersion)
        guard response.type == "response", response.ok, response.topic == topic else {
            throw TmuxSettingsError.invalidResponse
        }
        return response.data
    }
}

public enum TmuxSettingsError: LocalizedError {
    case invalidResponse

    public var errorDescription: String? { "Invalid tmux settings response" }
}
