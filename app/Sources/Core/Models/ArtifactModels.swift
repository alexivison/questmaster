import Foundation

public struct ArtifactReference: Decodable, Equatable, Identifiable {
    public var id: String
    public var resolvedKind: ArtifactKind { ArtifactKind.classify(kind: kind, path: path) }
    public var kind: String
    public var path: String
    public var label: String
    public var sessionID: String
    public var sessionIDs: [String]
    public var createdBySessionID: String
    public var projectID: String
    public var addedAt: String
    public var missing: Bool

    public init(
        kind: String,
        path: String,
        label: String,
        sessionID: String = "",
        projectID: String = "",
        addedAt: String,
        missing: Bool = false,
        id: String? = nil,
        sessionIDs: [String]? = nil,
        createdBySessionID: String = ""
    ) {
        self.id = id ?? path
        self.kind = kind
        self.path = path
        self.label = label
        self.sessionID = sessionID
        self.sessionIDs = sessionIDs ?? (sessionID.isEmpty ? [] : [sessionID])
        self.createdBySessionID = createdBySessionID
        self.projectID = projectID
        self.addedAt = addedAt
        self.missing = missing
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case path
        case label
        case session_id
        case id
        case session_ids
        case created_by_session_id
        case project_id
        case added_at
        case missing
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? path
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "html"
        label = try container.decodeIfPresent(String.self, forKey: .label)
            ?? URL(fileURLWithPath: path).lastPathComponent
        sessionID = try container.decodeIfPresent(String.self, forKey: .session_id) ?? ""
        sessionIDs = try container.decodeIfPresent([String].self, forKey: .session_ids)
            ?? (sessionID.isEmpty ? [] : [sessionID])
        if sessionID.isEmpty {
            sessionID = sessionIDs.first ?? ""
        }
        createdBySessionID = try container.decodeIfPresent(String.self, forKey: .created_by_session_id) ?? ""
        projectID = try container.decodeIfPresent(String.self, forKey: .project_id) ?? ""
        addedAt = try container.decodeIfPresent(String.self, forKey: .added_at) ?? ""
        missing = try container.decodeIfPresent(Bool.self, forKey: .missing) ?? false
    }
}

public enum ArtifactScope: String, CaseIterable, Equatable {
    case session
    case project
    case all
}

public enum ArtifactFilterTokenKind: String, CaseIterable {
    case project
    case type

    public var prefix: String { "@\(rawValue)" }
    public var command: String { "\(prefix):" }
}

public struct ArtifactFilterToken: Equatable, Identifiable {
    public var kind: ArtifactFilterTokenKind
    public var value: String
    public var title: String

    public init(kind: ArtifactFilterTokenKind, value: String, title: String) {
        self.kind = kind
        self.value = value
        self.title = title
    }

    public var id: String { "\(kind.rawValue):\(value)" }
}
