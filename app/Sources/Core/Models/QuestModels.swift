import Foundation

public struct QuestItem: Decodable, Equatable, Identifiable {
    public var id: String
    public var content: String
    public var projectID: String
    public var projectPath: String
    public var projectName: String
    public var done: Bool
    public var createdAt: String
    public var updatedAt: String
    public var sessionID: String

    public init(
        id: String,
        content: String,
        projectID: String = "",
        projectPath: String = "",
        projectName: String = "",
        done: Bool = false,
        createdAt: String = "",
        updatedAt: String = "",
        sessionID: String = ""
    ) {
        self.id = id
        self.content = content
        self.projectID = projectID
        self.projectPath = projectPath
        self.projectName = projectName
        self.done = done
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sessionID = sessionID
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case content
        case project_id
        case project_path
        case project_name
        case done
        case created_at
        case updated_at
        case session_id
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        projectID = try container.decodeIfPresent(String.self, forKey: .project_id) ?? ""
        projectPath = try container.decodeIfPresent(String.self, forKey: .project_path) ?? ""
        projectName = try container.decodeIfPresent(String.self, forKey: .project_name) ?? ""
        done = try container.decodeIfPresent(Bool.self, forKey: .done) ?? false
        createdAt = try container.decodeIfPresent(String.self, forKey: .created_at) ?? ""
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updated_at) ?? ""
        sessionID = try container.decodeIfPresent(String.self, forKey: .session_id) ?? ""
    }
}

public enum QuestScope: String, CaseIterable, Equatable {
    case active
    case done
}
