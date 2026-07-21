import Foundation

public struct TrackerSnapshot: Decodable, Equatable {
    public var repos: [TrackerRepo]
    public var projects: [TrackerProject]
    public var artifacts: [ArtifactReference]
    public var quests: [QuestItem]

    public init(
        repos: [TrackerRepo],
        projects: [TrackerProject] = [],
        artifacts: [ArtifactReference] = [],
        quests: [QuestItem] = []
    ) {
        self.repos = repos
        self.projects = projects
        self.artifacts = artifacts
        self.quests = quests
    }

    private enum CodingKeys: String, CodingKey {
        case repos
        case sessions
        case projects
        case artifacts
        case quests
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        artifacts = try container.decodeIfPresent([ArtifactReference].self, forKey: .artifacts) ?? []
        quests = try container.decodeIfPresent([QuestItem].self, forKey: .quests) ?? []
        projects = try container.decodeIfPresent([TrackerProject].self, forKey: .projects) ?? []
        if let repos = try container.decodeIfPresent([TrackerRepo].self, forKey: .repos) {
            self.repos = repos
            return
        }
        let sessions = try container.decodeIfPresent([TrackerSession].self, forKey: .sessions) ?? []
        self.repos = TrackerRepo.grouping(sessions)
    }
}

public struct TrackerProject: Decodable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var path: String
    public var color: String

    public init(id: String, name: String, path: String = "", color: String = "") {
        self.id = id
        self.name = name
        self.path = path
        self.color = color
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case identity
        case name
        case path
        case color
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
            ?? container.decodeIfPresent(String.self, forKey: .identity)
            ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        color = try container.decodeIfPresent(String.self, forKey: .color) ?? ""
    }
}

public struct TrackerRepo: Decodable, Equatable {
    public var id: String
    public var name: String
    public var path: String
    public var color: String
    public var sessions: [TrackerSession]

    public init(id: String, name: String, path: String = "", color: String = "", sessions: [TrackerSession]) {
        self.id = id
        self.name = name
        self.path = path
        self.color = color
        self.sessions = sessions
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case repo
        case path
        case color
        case sessions
        case rows
        case groups
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let repoRef = try? container.decode(RepoReference.self, forKey: .repo)
        let repoString = try? container.decode(String.self, forKey: .repo)
        id = try container.decodeIfPresent(String.self, forKey: .id)
            ?? repoString
            ?? repoRef?.identity
            ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name)
            ?? repoString
            ?? repoRef?.name
            ?? id
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? repoRef?.path ?? ""
        color = try container.decodeIfPresent(String.self, forKey: .color)
            ?? repoRef?.color
            ?? ""
        sessions = try container.decodeIfPresent([TrackerSession].self, forKey: .sessions)
            ?? container.decodeIfPresent([TrackerSession].self, forKey: .rows)
            ?? []
        if sessions.isEmpty, let groups = try container.decodeIfPresent([TrackerSessionGroup].self, forKey: .groups) {
            sessions = groups.flatMap(\.sessions)
        }
    }

    public static func grouping(_ sessions: [TrackerSession]) -> [TrackerRepo] {
        let grouped = Dictionary(grouping: sessions) { session in
            if AgentKind(name: session.agent) == .shell {
                return "ungrouped"
            }
            if !session.repoIdentity.isEmpty {
                return session.repoIdentity
            }
            return session.repoName.isEmpty ? "ungrouped" : session.repoName
        }
        return grouped.keys.sorted().map { key in
            let rows = grouped[key] ?? []
            let first = rows.first
            return TrackerRepo(
                id: key == "ungrouped" ? key : first?.repoIdentity ?? key,
                name: key == "ungrouped" ? "ungrouped" : first?.repoName ?? key,
                path: key == "ungrouped" ? "" : first?.repoPath ?? "",
                color: key == "ungrouped" ? "" : first?.repoColor ?? "",
                sessions: rows
            )
        }
    }
}

public struct TrackerSessionGroup: Decodable, Equatable {
    public var sessions: [TrackerSession]

    private enum CodingKeys: String, CodingKey {
        case master
        case workers
        case sessions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var rows: [TrackerSession] = []
        if let master = try container.decodeIfPresent(TrackerSession.self, forKey: .master) {
            rows.append(master)
        }
        rows.append(contentsOf: try container.decodeIfPresent([TrackerSession].self, forKey: .workers) ?? [])
        rows.append(contentsOf: try container.decodeIfPresent([TrackerSession].self, forKey: .sessions) ?? [])
        sessions = rows
    }
}

public struct TrackerSession: Decodable, Equatable {
    public var id: String
    public var title: String
    public var repoIdentity: String
    public var repoName: String
    public var repoPath: String
    public var repoColor: String
    public var displayColor: String
    public var worktreePath: String
    public var agent: String
    public var role: String
    public var state: String
    public var lifecycle: String
    public var snippet: String
    public var lastKind: String
    public var parentID: String
    public var workerCount: Int
    public var duration: String
    public var elapsedSince: Date?
    public var elapsedSeedMS: Int?
    public var isCurrent: Bool
    public var artifacts: [ArtifactReference]

    public init(
        id: String,
        title: String,
        repoIdentity: String = "",
        repoName: String,
        repoPath: String = "",
        repoColor: String = "",
        displayColor: String = "",
        worktreePath: String = "",
        agent: String = "",
        role: String = "standalone",
        state: String = "idle",
        lifecycle: String = "active",
        snippet: String = "",
        lastKind: String = "",
        parentID: String = "",
        workerCount: Int = 0,
        duration: String = "",
        elapsedSince: Date? = nil,
        elapsedSeedMS: Int? = nil,
        isCurrent: Bool = false,
        artifacts: [ArtifactReference] = []
    ) {
        self.id = id
        self.title = title
        self.repoIdentity = repoIdentity
        self.repoName = repoName
        self.repoPath = repoPath
        self.repoColor = repoColor
        self.displayColor = displayColor
        self.worktreePath = worktreePath
        self.agent = agent
        self.role = role
        self.state = state
        self.lifecycle = lifecycle
        self.snippet = snippet
        self.lastKind = lastKind
        self.parentID = parentID
        self.workerCount = workerCount
        self.duration = duration
        self.elapsedSince = elapsedSince
        self.elapsedSeedMS = elapsedSeedMS
        self.isCurrent = isCurrent
        self.artifacts = artifacts
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case repo
        case display_color
        case worktree_path
        case agent
        case primary_agent
        case session_type
        case state
        case status
        case latest_activity
        case last_kind
        case parent_id
        case worker_count
        case elapsed_ms
        case elapsed_since
        case is_current
        case artifacts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let repoRef = try? container.decode(RepoReference.self, forKey: .repo)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? id
        repoIdentity = repoRef?.identity ?? ""
        repoName = repoRef?.name ?? ""
        repoPath = repoRef?.path ?? ""
        let decodedDisplayColor = try container.decodeIfPresent(String.self, forKey: .display_color)
        repoColor = repoRef?.color ?? decodedDisplayColor ?? ""
        displayColor = decodedDisplayColor ?? ""
        worktreePath = try container.decodeIfPresent(String.self, forKey: .worktree_path) ?? ""
        agent = try container.decodeIfPresent(String.self, forKey: .agent)
            ?? container.decodeIfPresent(String.self, forKey: .primary_agent)
            ?? ""
        role = try container.decodeIfPresent(String.self, forKey: .session_type) ?? "standalone"
        lifecycle = try container.decode(String.self, forKey: .status)
        state = try container.decodeIfPresent(String.self, forKey: .state)
            ?? (lifecycle == "stopped" ? "stopped" : "idle")
        snippet = try container.decodeIfPresent(String.self, forKey: .latest_activity) ?? ""
        lastKind = try container.decodeIfPresent(String.self, forKey: .last_kind) ?? ""
        parentID = try container.decodeIfPresent(String.self, forKey: .parent_id) ?? ""
        workerCount = try container.decode(Int.self, forKey: .worker_count)
        elapsedSeedMS = try container.decode(Int.self, forKey: .elapsed_ms)
        elapsedSince = TrackerSession.parseInstant(
            try container.decodeIfPresent(String.self, forKey: .elapsed_since)
        )
        duration = TrackerSession.formatElapsed(elapsedSeedMS) ?? ""
        isCurrent = try container.decode(Bool.self, forKey: .is_current)
        artifacts = try container.decodeIfPresent([ArtifactReference].self, forKey: .artifacts) ?? []
    }

    public func duration(at date: Date) -> String {
        if let elapsedSince {
            let elapsed = max(0, Int(date.timeIntervalSince(elapsedSince) * 1000))
            return TrackerSession.formatElapsed(elapsed) ?? ""
        }
        if let elapsedSeedMS {
            return TrackerSession.formatElapsed(elapsedSeedMS) ?? ""
        }
        return duration
    }

    public static func formatElapsed(_ milliseconds: Int?) -> String? {
        guard let milliseconds, milliseconds > 0 else {
            return nil
        }
        let totalSeconds = milliseconds / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if minutes >= 60 {
            return "\(minutes / 60)h\(minutes % 60)m"
        }
        if minutes > 0 {
            return "\(minutes)m\(seconds)s"
        }
        return "\(seconds)s"
    }

    private static let fractionalInstantFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plainInstantFormatter = ISO8601DateFormatter()

    private static func parseInstant(_ value: String?) -> Date? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        if let date = fractionalInstantFormatter.date(from: value) {
            return date
        }
        return plainInstantFormatter.date(from: value)
    }

}
