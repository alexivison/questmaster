import Foundation

public struct ArtifactReference: Decodable, Equatable, Identifiable {
    public var id: String { path }
    public var resolvedKind: ArtifactKind { ArtifactKind.classify(kind: kind, path: path) }
    public var kind: String
    public var path: String
    public var label: String
    public var sessionID: String
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
        missing: Bool = false
    ) {
        self.kind = kind
        self.path = path
        self.label = label
        self.sessionID = sessionID
        self.projectID = projectID
        self.addedAt = addedAt
        self.missing = missing
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case path
        case label
        case session_id
        case project_id
        case added_at
        case missing
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "html"
        label = try container.decodeIfPresent(String.self, forKey: .label)
            ?? URL(fileURLWithPath: path).lastPathComponent
        sessionID = try container.decodeIfPresent(String.self, forKey: .session_id) ?? ""
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
