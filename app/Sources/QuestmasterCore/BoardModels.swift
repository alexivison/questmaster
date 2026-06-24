import Foundation

public struct BoardSnapshot: Decodable {
    public var repos: [QuestRepo]

    public init(repos: [QuestRepo]) {
        self.repos = repos
    }

    public var firstQuest: QuestDocument? {
        repos.lazy.flatMap(\.quests).first
    }

    public func quest(id: String) -> QuestDocument? {
        repos.lazy.flatMap(\.quests).first { $0.id == id }
    }

    public func count(status: String) -> Int {
        repos.flatMap(\.quests).filter { $0.status == status }.count
    }

    private enum CodingKeys: String, CodingKey {
        case repos
        case groups
        case quests
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.repos) {
            self.repos = container.decodeLossyArray(QuestRepo.self, forKey: .repos)
            return
        }
        if container.contains(.groups) {
            let groups = container.decodeLossyArray(ServeBoardGroup.self, forKey: .groups)
            self.repos = groups.map(\.repo)
            return
        }
        let quests = container.decodeLossyArray(QuestDocument.self, forKey: .quests)
        self.repos = QuestRepo.grouping(quests)
    }
}

public struct ServeBoardGroup: Decodable {
    public var repo: QuestRepo

    private enum CodingKeys: String, CodingKey {
        case repo
        case quests
        case items
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let repoRef = try container.decodeIfPresent(RepoReference.self, forKey: .repo) ?? RepoReference()
        let entries = container.contains(.quests)
            ? container.decodeLossyArray(ServeBoardQuest.self, forKey: .quests)
            : container.decodeLossyArray(ServeBoardQuest.self, forKey: .items)
        repo = QuestRepo(
            id: repoRef.identity,
            name: repoRef.name,
            path: repoRef.path,
            color: repoRef.color,
            quests: entries.map(\.quest)
        )
    }
}

public struct ServeBoardQuest: Decodable {
    public var quest: QuestDocument

    private enum CodingKeys: String, CodingKey {
        case quest
        case runtime
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        quest = try container.decode(QuestDocument.self, forKey: .quest)
        if let runtime = try container.decodeIfPresent(QuestRuntime.self, forKey: .runtime) {
            quest.runtime = runtime
        }
    }
}

public struct QuestRepo: Decodable {
    public var id: String
    public var name: String
    public var path: String
    public var color: String
    public var quests: [QuestDocument]

    public init(id: String, name: String, path: String = "", color: String = "", quests: [QuestDocument]) {
        self.id = id
        self.name = name
        self.path = path
        self.color = color
        self.quests = quests
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case repo
        case path
        case color
        case quests
        case items
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let repoRef = try? container.decode(RepoReference.self, forKey: .repo)
        id = try container.decodeIfPresent(String.self, forKey: .id)
            ?? repoRef?.identity
            ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name)
            ?? repoRef?.name
            ?? id
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? repoRef?.path ?? ""
        color = try container.decodeIfPresent(String.self, forKey: .color)
            ?? repoRef?.color
            ?? ""
        quests = container.contains(.quests)
            ? container.decodeLossyArray(QuestDocument.self, forKey: .quests)
            : container.decodeLossyArray(QuestDocument.self, forKey: .items)
    }

    public static func grouping(_ quests: [QuestDocument]) -> [QuestRepo] {
        let grouped = Dictionary(grouping: quests) { quest in
            quest.project.isEmpty ? "ungrouped" : quest.project
        }
        return grouped.keys.sorted().map { key in
            QuestRepo(
                id: key,
                name: key == "ungrouped" ? "ungrouped" : key,
                quests: grouped[key] ?? []
            )
        }
    }
}
