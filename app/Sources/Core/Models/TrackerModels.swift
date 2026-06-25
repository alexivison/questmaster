import Foundation

public struct TrackerSnapshot: Decodable {
    public var repos: [TrackerRepo]

    public init(repos: [TrackerRepo]) {
        self.repos = repos
    }

    private enum CodingKeys: String, CodingKey {
        case repos
        case sessions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let repos = try container.decodeIfPresent([TrackerRepo].self, forKey: .repos) {
            self.repos = repos
            return
        }
        let sessions = try container.decodeIfPresent([TrackerSession].self, forKey: .sessions) ?? []
        self.repos = TrackerRepo.grouping(sessions)
    }
}

public struct TrackerRepo: Decodable {
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
            if !session.repoIdentity.isEmpty {
                return session.repoIdentity
            }
            return session.repoName.isEmpty ? "ungrouped" : session.repoName
        }
        return grouped.keys.sorted().map { key in
            let rows = grouped[key] ?? []
            let first = rows.first
            return TrackerRepo(
                id: first?.repoIdentity ?? key,
                name: key == "ungrouped" ? "ungrouped" : first?.repoName ?? key,
                path: first?.repoPath ?? "",
                color: first?.repoColor ?? "",
                sessions: rows
            )
        }
    }
}

public struct TrackerSessionGroup: Decodable {
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

public struct TrackerSession: Decodable {
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
    public var questID: String
    public var questTitle: String
    public var parentID: String
    public var workerCount: Int
    public var duration: String
    public var elapsedSince: Date?
    public var elapsedSeedMS: Int?
    public var branch: String
    public var prStatus: String
    public var devServerPort: String
    public var isCurrent: Bool

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
        questID: String = "",
        questTitle: String = "",
        parentID: String = "",
        workerCount: Int = 0,
        duration: String = "",
        elapsedSince: Date? = nil,
        elapsedSeedMS: Int? = nil,
        branch: String = "",
        prStatus: String = "",
        devServerPort: String = "",
        isCurrent: Bool = false
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
        self.questID = questID
        self.questTitle = questTitle
        self.parentID = parentID
        self.workerCount = workerCount
        self.duration = duration
        self.elapsedSince = elapsedSince
        self.elapsedSeedMS = elapsedSeedMS
        self.branch = branch
        self.prStatus = prStatus
        self.devServerPort = devServerPort
        self.isCurrent = isCurrent
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
        case quest_id
        case quest_title
        case parent_id
        case worker_count
        case elapsed_ms
        case elapsed_since
        case is_current
        case quest_loop
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
        questID = try container.decodeIfPresent(String.self, forKey: .quest_id) ?? ""
        questTitle = try container.decodeIfPresent(String.self, forKey: .quest_title) ?? ""
        parentID = try container.decodeIfPresent(String.self, forKey: .parent_id) ?? ""
        workerCount = try container.decode(Int.self, forKey: .worker_count)
        elapsedSeedMS = try container.decode(Int.self, forKey: .elapsed_ms)
        elapsedSince = TrackerSession.parseInstant(
            try container.decodeIfPresent(String.self, forKey: .elapsed_since)
        )
        duration = TrackerSession.formatElapsed(elapsedSeedMS) ?? ""
        branch = ""
        prStatus = ""
        devServerPort = ""
        isCurrent = try container.decode(Bool.self, forKey: .is_current)
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

    private static func parseInstant(_ value: String?) -> Date? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        return ISO8601DateFormatter().date(from: value)
    }

}

extension TrackerSession: TrackerSessionLogic {
    public var trackerID: String { id }
    public var trackerState: String { state }
    public var trackerLifecycle: String { lifecycle }
    public var trackerLastKind: String { lastKind }
}

extension TrackerSession: TrackerDeletionCandidate {
    public var trackerRole: String { role }
    public var trackerParentID: String { parentID }
}
