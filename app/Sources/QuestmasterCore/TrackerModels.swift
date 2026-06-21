import Foundation

public struct TrackerSnapshot: Decodable {
    public var repos: [TrackerRepo]

    public init(repos: [TrackerRepo]) {
        self.repos = repos
    }

    private enum CodingKeys: String, CodingKey {
        case repos
        case sessions
        case sessionDetails
        case session_details
        case adventurers
        case observedAt
        case observed_at
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let repos = try container.decodeIfPresent([TrackerRepo].self, forKey: .repos) {
            self.repos = repos
            return
        }
        let sessions = try container.decodeIfPresent([TrackerSession].self, forKey: .sessionDetails)
            ?? container.decodeIfPresent([TrackerSession].self, forKey: .session_details)
            ?? container.decodeIfPresent([TrackerSession].self, forKey: .sessions)
            ?? container.decodeIfPresent([TrackerSession].self, forKey: .adventurers)
            ?? []
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
        case repoColor
        case repo_color
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
            ?? container.decodeIfPresent(String.self, forKey: .repoColor)
            ?? container.decodeIfPresent(String.self, forKey: .repo_color)
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
        case sessionID
        case session_id
        case title
        case name
        case repo
        case repoIdentity
        case repo_identity
        case repoName
        case repo_name
        case repoPath
        case repo_path
        case repoColor
        case repo_color
        case displayColor
        case display_color
        case cwd
        case path
        case worktreePath
        case worktree_path
        case agent
        case primaryAgent
        case primary_agent
        case role
        case sessionType
        case session_type
        case state
        case status
        case lifecycle
        case snippet
        case latestActivity
        case latest_activity
        case lastKind
        case last_kind
        case questID
        case quest_id
        case questTitle
        case quest_title
        case parentID
        case parent_id
        case workerCount
        case worker_count
        case duration
        case elapsed
        case elapsedMS
        case elapsed_ms
        case elapsedSince
        case elapsed_since
        case branch
        case branchName
        case branch_name
        case gitBranch
        case git_branch
        case prStatus
        case pr_status
        case pullRequest
        case pull_request
        case devServerPort
        case dev_server_port
        case port
        case current
        case isCurrent
        case is_current
        case questLoop
        case quest_loop
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let repoRef = try? container.decode(RepoReference.self, forKey: .repo)
        id = try container.decodeIfPresent(String.self, forKey: .id)
            ?? container.decodeIfPresent(String.self, forKey: .sessionID)
            ?? container.decodeIfPresent(String.self, forKey: .session_id)
            ?? ""
        title = try container.decodeIfPresent(String.self, forKey: .title)
            ?? container.decodeIfPresent(String.self, forKey: .name)
            ?? id
        repoIdentity = try container.decodeIfPresent(String.self, forKey: .repoIdentity)
            ?? container.decodeIfPresent(String.self, forKey: .repo_identity)
            ?? repoRef?.identity
            ?? ""
        repoName = try container.decodeIfPresent(String.self, forKey: .repoName)
            ?? container.decodeIfPresent(String.self, forKey: .repo_name)
            ?? repoRef?.name
            ?? ""
        repoPath = try container.decodeIfPresent(String.self, forKey: .repoPath)
            ?? container.decodeIfPresent(String.self, forKey: .repo_path)
            ?? repoRef?.path
            ?? ""
        let decodedDisplayColor = try container.decodeIfPresent(String.self, forKey: .displayColor)
            ?? container.decodeIfPresent(String.self, forKey: .display_color)
        repoColor = try container.decodeIfPresent(String.self, forKey: .repoColor)
            ?? container.decodeIfPresent(String.self, forKey: .repo_color)
            ?? repoRef?.color
            ?? decodedDisplayColor
            ?? ""
        displayColor = decodedDisplayColor ?? ""
        worktreePath = try container.decodeIfPresent(String.self, forKey: .worktreePath)
            ?? container.decodeIfPresent(String.self, forKey: .worktree_path)
            ?? container.decodeIfPresent(String.self, forKey: .path)
            ?? container.decodeIfPresent(String.self, forKey: .cwd)
            ?? ""
        agent = try container.decodeIfPresent(String.self, forKey: .agent)
            ?? container.decodeIfPresent(String.self, forKey: .primaryAgent)
            ?? container.decodeIfPresent(String.self, forKey: .primary_agent)
            ?? ""
        role = try container.decodeIfPresent(String.self, forKey: .role)
            ?? container.decodeIfPresent(String.self, forKey: .sessionType)
            ?? container.decodeIfPresent(String.self, forKey: .session_type)
            ?? "standalone"
        lifecycle = try container.decodeIfPresent(String.self, forKey: .lifecycle)
            ?? container.decodeIfPresent(String.self, forKey: .status)
            ?? "active"
        state = try container.decodeIfPresent(String.self, forKey: .state)
            ?? (lifecycle == "stopped" ? "stopped" : "idle")
        snippet = try container.decodeIfPresent(String.self, forKey: .snippet)
            ?? container.decodeIfPresent(String.self, forKey: .latestActivity)
            ?? container.decodeIfPresent(String.self, forKey: .latest_activity)
            ?? ""
        lastKind = try container.decodeIfPresent(String.self, forKey: .lastKind)
            ?? container.decodeIfPresent(String.self, forKey: .last_kind)
            ?? ""
        questID = try container.decodeIfPresent(String.self, forKey: .questID)
            ?? container.decodeIfPresent(String.self, forKey: .quest_id)
            ?? ""
        questTitle = try container.decodeIfPresent(String.self, forKey: .questTitle)
            ?? container.decodeIfPresent(String.self, forKey: .quest_title)
            ?? ""
        parentID = try container.decodeIfPresent(String.self, forKey: .parentID)
            ?? container.decodeIfPresent(String.self, forKey: .parent_id)
            ?? ""
        workerCount = try container.decodeIfPresent(Int.self, forKey: .workerCount)
            ?? container.decodeIfPresent(Int.self, forKey: .worker_count)
            ?? 0
        elapsedSeedMS = try container.decodeIfPresent(Int.self, forKey: .elapsedMS)
            ?? container.decodeIfPresent(Int.self, forKey: .elapsed_ms)
        elapsedSince = TrackerSession.parseInstant(
            try container.decodeIfPresent(String.self, forKey: .elapsedSince)
                ?? container.decodeIfPresent(String.self, forKey: .elapsed_since)
        )
        duration = try container.decodeIfPresent(String.self, forKey: .duration)
            ?? container.decodeIfPresent(String.self, forKey: .elapsed)
            ?? TrackerSession.formatElapsed(elapsedSeedMS)
            ?? ""
        branch = try container.decodeIfPresent(String.self, forKey: .branch)
            ?? container.decodeIfPresent(String.self, forKey: .branchName)
            ?? container.decodeIfPresent(String.self, forKey: .branch_name)
            ?? container.decodeIfPresent(String.self, forKey: .gitBranch)
            ?? container.decodeIfPresent(String.self, forKey: .git_branch)
            ?? ""
        prStatus = try container.decodeIfPresent(String.self, forKey: .prStatus)
            ?? container.decodeIfPresent(String.self, forKey: .pr_status)
            ?? container.decodeIfPresent(String.self, forKey: .pullRequest)
            ?? container.decodeIfPresent(String.self, forKey: .pull_request)
            ?? ""
        devServerPort = TrackerSession.decodePort(from: container)
        isCurrent = try container.decodeIfPresent(Bool.self, forKey: .isCurrent)
            ?? container.decodeIfPresent(Bool.self, forKey: .is_current)
            ?? container.decodeIfPresent(Bool.self, forKey: .current)
            ?? false
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

    private static func decodePort(from container: KeyedDecodingContainer<CodingKeys>) -> String {
        for key in [CodingKeys.devServerPort, .dev_server_port, .port] {
            if let value = try? container.decode(String.self, forKey: key), !value.isEmpty {
                return value
            }
            if let value = try? container.decode(Int.self, forKey: key), value > 0 {
                return "\(value)"
            }
        }
        return ""
    }
}

extension TrackerSession: TrackerSessionLogic {
    public var trackerID: String { id }
    public var trackerState: String { state }
    public var trackerLifecycle: String { lifecycle }
    public var trackerLastKind: String { lastKind }
}
