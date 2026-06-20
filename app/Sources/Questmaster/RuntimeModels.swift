import Foundation
import QuestmasterCore

struct RuntimeSnapshot {
    var tracker: TrackerSnapshot
    var board: BoardSnapshot
    var items: [WorkspaceItem]
    var activeQuestID: String?
    var activeQuest: QuestDocument?
    var observedLabel: String
    var sourceLabel: String
    var tick: Int

    static func empty(sourceLabel: String) -> RuntimeSnapshot {
        RuntimeSnapshot(
            tracker: TrackerSnapshot(repos: []),
            board: BoardSnapshot(repos: []),
            items: [],
            activeQuestID: nil,
            activeQuest: nil,
            observedLabel: "",
            sourceLabel: sourceLabel,
            tick: 0
        )
    }

    var serviceStateMessage: String? {
        let value = observedLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return nil
        }
        let lowercased = value.lowercased()
        guard lowercased.contains("connecting")
            || lowercased.contains("serve not connected")
            || lowercased.contains("serve not configured")
            || lowercased.contains("serve down") else {
            return nil
        }
        return value
    }

    var selectedQuest: QuestDocument? {
        if let activeQuest {
            return activeQuest
        }
        guard let activeQuestID else {
            return board.firstQuest
        }
        return board.quest(id: activeQuestID) ?? board.firstQuest
    }

    mutating func apply(_ update: RuntimeUpdate) {
        if let tracker = update.tracker {
            self.tracker = tracker
        }
        if let board = update.board {
            self.board = board
        }
        if let items = update.items {
            self.items = items
        }
        if let quest = update.quest {
            self.activeQuest = quest
            self.activeQuestID = quest.id
        }
        if let activeQuestID = update.activeQuestID {
            self.activeQuestID = activeQuestID
            if activeQuest?.id != activeQuestID {
                self.activeQuest = board.quest(id: activeQuestID)
            }
        }
        if let observedLabel = update.observedLabel {
            self.observedLabel = observedLabel
        }
        tick += 1
    }
}

extension RuntimeSnapshot {
    func item(id: String) -> WorkspaceItem? {
        items.first { $0.id == id }
    }

    func validItemID(preferredID: String?) -> String? {
        guard !items.isEmpty else {
            return nil
        }
        if let preferredID, items.contains(where: { $0.id == preferredID }) {
            return preferredID
        }
        return nil
    }
}

struct RuntimeUpdate: Decodable {
    var tracker: TrackerSnapshot?
    var board: BoardSnapshot?
    var items: [WorkspaceItem]?
    var quest: QuestDocument?
    var viewerItem: RuntimeViewerItem?
    var activeQuestID: String?
    var observedLabel: String?

    private enum CodingKeys: String, CodingKey {
        case type
        case data
        case tracker
        case board
        case items
        case quest
        case activeQuest
        case activeQuestID
        case activeQuestId
        case active_quest_id
        case observedAt
        case observed_at
    }

    init(
        tracker: TrackerSnapshot? = nil,
        board: BoardSnapshot? = nil,
        items: [WorkspaceItem]? = nil,
        quest: QuestDocument? = nil,
        viewerItem: RuntimeViewerItem? = nil,
        activeQuestID: String? = nil,
        observedLabel: String? = nil
    ) {
        self.tracker = tracker
        self.board = board
        self.items = items
        self.quest = quest
        self.viewerItem = viewerItem
        self.activeQuestID = activeQuestID
        self.observedLabel = observedLabel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decodeIfPresent(String.self, forKey: .type)

        tracker = try container.decodeIfPresent(TrackerSnapshot.self, forKey: .tracker)
        board = try container.decodeIfPresent(BoardSnapshot.self, forKey: .board)
        items = try container.decodeIfPresent([WorkspaceItem].self, forKey: .items)
        quest = try container.decodeIfPresent(QuestDocument.self, forKey: .quest)
            ?? container.decodeIfPresent(QuestDocument.self, forKey: .activeQuest)
        viewerItem = nil
        activeQuestID = try container.decodeIfPresent(String.self, forKey: .activeQuestID)
            ?? container.decodeIfPresent(String.self, forKey: .activeQuestId)
            ?? container.decodeIfPresent(String.self, forKey: .active_quest_id)
        observedLabel = try container.decodeIfPresent(String.self, forKey: .observedAt)
            ?? container.decodeIfPresent(String.self, forKey: .observed_at)

        guard container.contains(.data) else {
            return
        }

        switch type {
        case "tracker":
            tracker = try container.decodeIfPresent(TrackerSnapshot.self, forKey: .data) ?? tracker
        case "board":
            board = try container.decodeIfPresent(BoardSnapshot.self, forKey: .data) ?? board
        case "items":
            let payload = try container.decodeIfPresent(ItemsPayload.self, forKey: .data)
            items = payload?.items ?? items
            observedLabel = payload?.observedLabel ?? observedLabel
        case "quest", "active_quest", "activeQuest":
            quest = try container.decodeIfPresent(QuestDocument.self, forKey: .data) ?? quest
            activeQuestID = quest?.id ?? activeQuestID
        default:
            if let nested = try container.decodeIfPresent(RuntimeUpdate.self, forKey: .data) {
                tracker = tracker ?? nested.tracker
                board = board ?? nested.board
                items = items ?? nested.items
                quest = quest ?? nested.quest
                viewerItem = viewerItem ?? nested.viewerItem
                activeQuestID = activeQuestID ?? nested.activeQuestID
                observedLabel = observedLabel ?? nested.observedLabel
            }
        }
    }
}

extension RuntimeUpdate {
    static func serveUnavailable(_ message: String) -> RuntimeUpdate {
        RuntimeUpdate(
            tracker: TrackerSnapshot(repos: []),
            board: BoardSnapshot(repos: []),
            activeQuestID: "",
            observedLabel: message
        )
    }
}

struct RuntimeViewerItem: Decodable {
    var id: String
    var type: String
    var title: String
    var questID: String
    var path: String
    var url: String
    var html: String

    var normalizedType: String {
        let explicit = type.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty {
            return ItemViewerRegistry.normalizedType(explicit)
        }
        if !questID.isEmpty {
            return "quest"
        }
        if isHTMLPath(path) || isHTMLPath(url) {
            return "html"
        }
        return "unknown"
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case viewerType
        case viewer_type
        case contentType
        case content_type
        case title
        case questID
        case quest_id
        case path
        case file
        case url
        case html
        case content
    }

    init(
        id: String = "",
        type: String,
        title: String,
        questID: String = "",
        path: String = "",
        url: String = "",
        html: String = ""
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.questID = questID
        self.path = path
        self.url = url
        self.html = html
    }

    static func workspace(_ item: WorkspaceItem) -> RuntimeViewerItem {
        RuntimeViewerItem(
            id: item.id,
            type: item.type,
            title: item.displayTitle,
            path: item.artifact.path,
            html: item.artifact.inline
        )
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let raw = try? container.decode(String.self) {
            id = raw
            type = isHTMLPath(raw) ? "html" : "unknown"
            title = raw
            questID = ""
            path = raw
            url = ""
            html = ""
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        type = try container.decodeIfPresent(String.self, forKey: .type)
            ?? container.decodeIfPresent(String.self, forKey: .viewerType)
            ?? container.decodeIfPresent(String.self, forKey: .viewer_type)
            ?? container.decodeIfPresent(String.self, forKey: .contentType)
            ?? container.decodeIfPresent(String.self, forKey: .content_type)
            ?? ""
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? id
        questID = try container.decodeIfPresent(String.self, forKey: .questID)
            ?? container.decodeIfPresent(String.self, forKey: .quest_id)
            ?? ""
        path = try container.decodeIfPresent(String.self, forKey: .path)
            ?? container.decodeIfPresent(String.self, forKey: .file)
            ?? ""
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        html = try container.decodeIfPresent(String.self, forKey: .html)
            ?? container.decodeIfPresent(String.self, forKey: .content)
            ?? ""
    }
}

struct ItemsPayload: Decodable {
    var items: [WorkspaceItem]
    var observedLabel: String

    private enum CodingKeys: String, CodingKey {
        case items
        case observedAt
        case observed_at
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = container.decodeLossyArray(WorkspaceItem.self, forKey: .items)
        observedLabel = try container.decodeIfPresent(String.self, forKey: .observedAt)
            ?? container.decodeIfPresent(String.self, forKey: .observed_at)
            ?? ""
    }
}

struct WorkspaceItem: Decodable {
    var id: String
    var type: String
    var title: String
    var createdAt: String
    var artifact: WorkspaceArtifact
    var loose: Bool
    var attachmentCount: Int
    var questIDs: [String]

    var displayTitle: String {
        title.isEmpty ? id : title
    }

    var metaLabel: String {
        let usage = loose ? "loose" : "\(attachmentCount) quest\(attachmentCount == 1 ? "" : "s")"
        let source: String
        if !artifact.path.isEmpty {
            source = URL(fileURLWithPath: artifact.path).lastPathComponent
        } else if !artifact.inline.isEmpty {
            source = "inline"
        } else {
            source = "empty"
        }
        return "\(type.isEmpty ? "unknown" : type)  \(usage)  \(source)"
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case title
        case createdAt
        case created_at
        case artifact
        case path
        case inline
        case html
        case content
        case loose
        case attachmentCount
        case attachment_count
        case questIDs
        case quest_ids
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? id
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
            ?? container.decodeIfPresent(String.self, forKey: .created_at)
            ?? ""
        artifact = try container.decodeIfPresent(WorkspaceArtifact.self, forKey: .artifact)
            ?? WorkspaceArtifact(
                path: try container.decodeIfPresent(String.self, forKey: .path) ?? "",
                inline: try container.decodeIfPresent(String.self, forKey: .inline)
                    ?? container.decodeIfPresent(String.self, forKey: .html)
                    ?? container.decodeIfPresent(String.self, forKey: .content)
                    ?? ""
            )
        loose = try container.decodeIfPresent(Bool.self, forKey: .loose) ?? false
        attachmentCount = try container.decodeIfPresent(Int.self, forKey: .attachmentCount)
            ?? container.decodeIfPresent(Int.self, forKey: .attachment_count)
            ?? 0
        questIDs = try container.decodeIfPresent([String].self, forKey: .questIDs)
            ?? container.decodeIfPresent([String].self, forKey: .quest_ids)
            ?? []
    }
}

struct WorkspaceArtifact: Decodable {
    var path: String
    var inline: String

    init(path: String = "", inline: String = "") {
        self.path = path
        self.inline = inline
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case inline
        case html
        case content
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        inline = try container.decodeIfPresent(String.self, forKey: .inline)
            ?? container.decodeIfPresent(String.self, forKey: .html)
            ?? container.decodeIfPresent(String.self, forKey: .content)
            ?? ""
    }
}

private func isHTMLPath(_ value: String) -> Bool {
    let lower = value.lowercased()
    return lower.hasSuffix(".html") || lower.hasSuffix(".htm")
}

struct TrackerSnapshot: Decodable {
    var repos: [TrackerRepo]

    init(repos: [TrackerRepo]) {
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

    init(from decoder: Decoder) throws {
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

struct TrackerRepo: Decodable {
    var id: String
    var name: String
    var path: String
    var color: String
    var sessions: [TrackerSession]

    init(id: String, name: String, path: String = "", color: String = "", sessions: [TrackerSession]) {
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

    init(from decoder: Decoder) throws {
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

    static func grouping(_ sessions: [TrackerSession]) -> [TrackerRepo] {
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

struct TrackerSessionGroup: Decodable {
    var sessions: [TrackerSession]

    private enum CodingKeys: String, CodingKey {
        case master
        case workers
        case sessions
    }

    init(from decoder: Decoder) throws {
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

struct TrackerSession: Decodable {
    var id: String
    var title: String
    var repoIdentity: String
    var repoName: String
    var repoPath: String
    var repoColor: String
    var displayColor: String
    var worktreePath: String
    var agent: String
    var role: String
    var state: String
    var lifecycle: String
    var snippet: String
    var lastKind: String
    var questID: String
    var questTitle: String
    var parentID: String
    var workerCount: Int
    var duration: String
    var elapsedSince: Date?
    var elapsedSeedMS: Int?
    var branch: String
    var prStatus: String
    var devServerPort: String
    var isCurrent: Bool

    init(
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

    init(from decoder: Decoder) throws {
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

    func duration(at date: Date) -> String {
        if let elapsedSince {
            let elapsed = max(0, Int(date.timeIntervalSince(elapsedSince) * 1000))
            return TrackerSession.formatElapsed(elapsed) ?? ""
        }
        if let elapsedSeedMS {
            return TrackerSession.formatElapsed(elapsedSeedMS) ?? ""
        }
        return duration
    }

    static func formatElapsed(_ milliseconds: Int?) -> String? {
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
    var trackerID: String { id }
    var trackerState: String { state }
    var trackerLifecycle: String { lifecycle }
    var trackerLastKind: String { lastKind }
}

struct BoardSnapshot: Decodable {
    var repos: [QuestRepo]

    init(repos: [QuestRepo]) {
        self.repos = repos
    }

    var firstQuest: QuestDocument? {
        repos.lazy.flatMap(\.quests).first
    }

    func quest(id: String) -> QuestDocument? {
        repos.lazy.flatMap(\.quests).first { $0.id == id }
    }

    func count(status: String) -> Int {
        repos.flatMap(\.quests).filter { $0.status == status }.count
    }

    private enum CodingKeys: String, CodingKey {
        case repos
        case groups
        case quests
        case observedAt
        case observed_at
    }

    init(from decoder: Decoder) throws {
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

struct ServeBoardGroup: Decodable {
    var repo: QuestRepo

    private enum CodingKeys: String, CodingKey {
        case repo
        case quests
        case items
    }

    init(from decoder: Decoder) throws {
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

struct ServeBoardQuest: Decodable {
    var quest: QuestDocument

    private enum CodingKeys: String, CodingKey {
        case quest
        case runtime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        quest = try container.decode(QuestDocument.self, forKey: .quest)
        if let runtime = try container.decodeIfPresent(QuestRuntime.self, forKey: .runtime) {
            quest.runtime = runtime
        }
    }
}

struct QuestRepo: Decodable {
    var id: String
    var name: String
    var path: String
    var color: String
    var quests: [QuestDocument]

    init(id: String, name: String, path: String = "", color: String = "", quests: [QuestDocument]) {
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
        case repoColor
        case repo_color
        case quests
        case items
    }

    init(from decoder: Decoder) throws {
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
            ?? container.decodeIfPresent(String.self, forKey: .repoColor)
            ?? container.decodeIfPresent(String.self, forKey: .repo_color)
            ?? repoRef?.color
            ?? ""
        quests = container.contains(.quests)
            ? container.decodeLossyArray(QuestDocument.self, forKey: .quests)
            : container.decodeLossyArray(QuestDocument.self, forKey: .items)
    }

    static func grouping(_ quests: [QuestDocument]) -> [QuestRepo] {
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

struct QuestDocument: Decodable {
    var id: String
    var title: String
    var status: String
    var summary: String
    var date: String
    var project: String
    var related: [RelatedLink]
    var attachments: [QuestAttachmentRef]
    var gates: [QuestGate]
    var body: [QuestBlock]
    var comments: [QuestComment]
    var runtime: QuestRuntime
    var commentCount: Int

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case status
        case summary
        case objective
        case date
        case project
        case repo
        case related
        case attachments
        case gates
        case body
        case comments
        case runtime
        case commentCount
        case comment_count
    }

    init(
        id: String,
        title: String,
        status: String,
        summary: String,
        date: String,
        project: String,
        related: [RelatedLink],
        attachments: [QuestAttachmentRef] = [],
        gates: [QuestGate],
        body: [QuestBlock],
        comments: [QuestComment],
        runtime: QuestRuntime,
        commentCount: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.summary = summary
        self.date = date
        self.project = project
        self.related = related
        self.attachments = attachments
        self.gates = gates
        self.body = body
        self.comments = comments
        self.runtime = runtime
        self.commentCount = commentCount ?? comments.filter { $0.status != "resolved" }.count
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? id
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "wip"
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
            ?? container.decodeIfPresent(String.self, forKey: .objective)
            ?? ""
        date = try container.decodeIfPresent(String.self, forKey: .date) ?? ""
        project = try container.decodeIfPresent(String.self, forKey: .project)
            ?? container.decodeIfPresent(String.self, forKey: .repo)
            ?? ""
        related = container.decodeLossyArray(RelatedLink.self, forKey: .related)
        attachments = container.decodeLossyArray(QuestAttachmentRef.self, forKey: .attachments)
        gates = container.decodeLossyArray(QuestGate.self, forKey: .gates)
        body = container.decodeLossyArray(QuestBlock.self, forKey: .body)
        comments = container.decodeLossyArray(QuestComment.self, forKey: .comments)
        runtime = try container.decodeIfPresent(QuestRuntime.self, forKey: .runtime) ?? QuestRuntime()
        commentCount = try container.decodeIfPresent(Int.self, forKey: .commentCount)
            ?? container.decodeIfPresent(Int.self, forKey: .comment_count)
            ?? comments.filter { $0.status != "resolved" }.count
    }
}

struct QuestRuntime: Decodable {
    var sessions: [String]
    var sessionDetails: [QuestAdventurer]
    var adventurers: [QuestAdventurer]
    var agent: String
    var gates: [String: String]
    var gatesAt: [String: String]
    var observedAt: String
    var loop: QuestLoop?

    init(
        sessions: [String] = [],
        sessionDetails: [QuestAdventurer] = [],
        adventurers: [QuestAdventurer] = [],
        agent: String = "",
        gates: [String: String] = [:],
        gatesAt: [String: String] = [:],
        observedAt: String = "",
        loop: QuestLoop? = nil
    ) {
        self.sessions = sessions
        self.sessionDetails = sessionDetails.isEmpty ? adventurers : sessionDetails
        self.adventurers = adventurers
        self.agent = agent
        self.gates = gates
        self.gatesAt = gatesAt
        self.observedAt = observedAt
        self.loop = loop
    }

    private enum CodingKeys: String, CodingKey {
        case sessions
        case sessionDetails
        case session_details
        case adventurers
        case agent
        case gates
        case gatesAt
        case gates_at
        case observedAt
        case observed_at
        case loop
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let canonicalDetails = try container.decodeIfPresent([QuestAdventurer].self, forKey: .sessionDetails)
            ?? container.decodeIfPresent([QuestAdventurer].self, forKey: .session_details)
            ?? []
        let legacyAdventurers = try container.decodeIfPresent([QuestAdventurer].self, forKey: .adventurers) ?? []
        sessionDetails = canonicalDetails.isEmpty ? legacyAdventurers : canonicalDetails
        adventurers = sessionDetails
        sessions = try container.decodeIfPresent([String].self, forKey: .sessions) ?? adventurers.map(\.id)
        agent = try container.decodeIfPresent(String.self, forKey: .agent) ?? ""
        gates = try container.decodeIfPresent([String: String].self, forKey: .gates) ?? [:]
        gatesAt = try container.decodeIfPresent([String: String].self, forKey: .gatesAt)
            ?? container.decodeIfPresent([String: String].self, forKey: .gates_at)
            ?? [:]
        observedAt = try container.decodeIfPresent(String.self, forKey: .observedAt)
            ?? container.decodeIfPresent(String.self, forKey: .observed_at)
            ?? ""
        loop = try container.decodeIfPresent(QuestLoop.self, forKey: .loop)
    }
}

struct QuestPayload: Decodable {
    var quest: QuestDocument
    var observedLabel: String

    private enum CodingKeys: String, CodingKey {
        case quest
        case runtime
        case observedAt
        case observed_at
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        quest = try container.decode(QuestDocument.self, forKey: .quest)
        if let runtime = try container.decodeIfPresent(QuestRuntime.self, forKey: .runtime) {
            quest.runtime = runtime
        }
        observedLabel = try container.decodeIfPresent(String.self, forKey: .observedAt)
            ?? container.decodeIfPresent(String.self, forKey: .observed_at)
            ?? ""
    }
}

struct QuestAdventurer: Decodable {
    var id: String
    var agent: String
    var state: String
    var since: String
    var loop: QuestLoop?

    init(id: String, agent: String, state: String, since: String = "", loop: QuestLoop? = nil) {
        self.id = id
        self.agent = agent
        self.state = state
        self.since = since
        self.loop = loop
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case agent
        case state
        case since
        case loop
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(String.self, forKey: .id) ?? "",
            agent: try container.decodeIfPresent(String.self, forKey: .agent) ?? "",
            state: try container.decodeIfPresent(String.self, forKey: .state) ?? "",
            since: try container.decodeIfPresent(String.self, forKey: .since) ?? "",
            loop: try container.decodeIfPresent(QuestLoop.self, forKey: .loop)
        )
    }
}

struct QuestLoop: Decodable {
    var sessionID: String
    var iterations: Int
    var lastVerdict: String
    var phase: String

    init(sessionID: String = "", iterations: Int = 0, lastVerdict: String = "", phase: String = "") {
        self.sessionID = sessionID
        self.iterations = iterations
        self.lastVerdict = lastVerdict
        self.phase = phase
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID
        case session_id
        case iterations
        case lastVerdict
        case last_verdict
        case phase
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
            ?? container.decodeIfPresent(String.self, forKey: .session_id)
            ?? ""
        iterations = try container.decodeIfPresent(Int.self, forKey: .iterations) ?? 0
        lastVerdict = try container.decodeIfPresent(String.self, forKey: .lastVerdict)
            ?? container.decodeIfPresent(String.self, forKey: .last_verdict)
            ?? ""
        phase = try container.decodeIfPresent(String.self, forKey: .phase) ?? ""
    }
}

struct QuestGate: Decodable {
    var name: String
    var type: String
    var check: String
    var before: String
    var checked: Bool

    init(name: String, type: String, check: String = "", before: String = "", checked: Bool = false) {
        self.name = name
        self.type = type
        self.check = check
        self.before = before
        self.checked = checked
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case type
        case check
        case before
        case checked
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decodeIfPresent(String.self, forKey: .name) ?? "",
            type: try container.decodeIfPresent(String.self, forKey: .type) ?? "",
            check: try container.decodeIfPresent(String.self, forKey: .check) ?? "",
            before: try container.decodeIfPresent(String.self, forKey: .before) ?? "",
            checked: try container.decodeIfPresent(Bool.self, forKey: .checked) ?? false
        )
    }
}

struct QuestBlock: Decodable {
    var type: String
    var id: String
    var level: Int
    var text: String
    var ordered: Bool
    var items: [String]
    var lang: String
    var format: String
    var fallback: String
    var content: String

    init(
        type: String,
        id: String = "",
        level: Int = 0,
        text: String = "",
        ordered: Bool = false,
        items: [String] = [],
        lang: String = "",
        format: String = "",
        fallback: String = "",
        content: String = ""
    ) {
        self.type = type
        self.id = id
        self.level = level
        self.text = text
        self.ordered = ordered
        self.items = items
        self.lang = lang
        self.format = format
        self.fallback = fallback
        self.content = content
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case id
        case level
        case text
        case ordered
        case items
        case lang
        case format
        case fallback
        case content
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            type: try container.decodeIfPresent(String.self, forKey: .type) ?? "",
            id: try container.decodeIfPresent(String.self, forKey: .id) ?? "",
            level: try container.decodeIfPresent(Int.self, forKey: .level) ?? 0,
            text: try container.decodeIfPresent(String.self, forKey: .text) ?? "",
            ordered: try container.decodeIfPresent(Bool.self, forKey: .ordered) ?? false,
            items: try container.decodeIfPresent([String].self, forKey: .items) ?? [],
            lang: try container.decodeIfPresent(String.self, forKey: .lang) ?? "",
            format: try container.decodeIfPresent(String.self, forKey: .format) ?? "",
            fallback: try container.decodeIfPresent(String.self, forKey: .fallback) ?? "",
            content: try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        )
    }
}

struct RelatedLink: Decodable {
    var id: String
    var type: String
    var title: String
    var url: String

    init(id: String = "", type: String = "", title: String, url: String = "") {
        self.id = id
        self.type = type
        self.title = title
        self.url = url
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let title = try? container.decode(String.self) {
            self.init(title: title)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedURL = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        self.init(
            id: try container.decodeIfPresent(String.self, forKey: .id) ?? "",
            type: try container.decodeIfPresent(String.self, forKey: .type) ?? "",
            title: try container.decodeIfPresent(String.self, forKey: .title) ?? decodedURL,
            url: decodedURL
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case title
        case url
    }
}

struct QuestAttachmentRef: Decodable {
    var itemID: String
    var type: String
    var title: String

    var linkURL: URL? {
        URL(string: "questmaster-item://\(itemID)")
    }

    init(itemID: String, type: String, title: String) {
        self.itemID = itemID
        self.type = type
        self.title = title
    }

    private enum CodingKeys: String, CodingKey {
        case itemID
        case item_id
        case type
        case title
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        itemID = try container.decodeIfPresent(String.self, forKey: .itemID)
            ?? container.decodeIfPresent(String.self, forKey: .item_id)
            ?? ""
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? itemID
    }
}

struct QuestComment: Decodable {
    var id: String
    var anchor: CommentAnchor
    var status: String
    var author: String
    var body: String
    var createdAt: String

    init(id: String, anchor: CommentAnchor, status: String, author: String, body: String, createdAt: String) {
        self.id = id
        self.anchor = anchor
        self.status = status
        self.author = author
        self.body = body
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case anchor
        case status
        case author
        case body
        case createdAt
        case created_at
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        anchor = try container.decodeIfPresent(CommentAnchor.self, forKey: .anchor) ?? CommentAnchor()
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "open"
        author = try container.decodeIfPresent(String.self, forKey: .author) ?? ""
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
            ?? container.decodeIfPresent(String.self, forKey: .created_at)
            ?? ""
    }
}

struct CommentAnchor: Decodable {
    var kind: String
    var id: String
    var item: Int?

    init(kind: String = "", id: String = "", item: Int? = nil) {
        self.kind = kind
        self.id = id
        self.item = item
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case id
        case item
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            kind: try container.decodeIfPresent(String.self, forKey: .kind) ?? "",
            id: try container.decodeIfPresent(String.self, forKey: .id) ?? "",
            item: try container.decodeIfPresent(Int.self, forKey: .item)
        )
    }
}

struct RepoReference: Decodable {
    var identity: String
    var name: String
    var color: String
    var path: String

    init(identity: String = "", name: String = "", color: String = "", path: String = "") {
        self.identity = identity
        self.name = name.isEmpty ? identity : name
        self.color = color
        self.path = path
    }

    private enum CodingKeys: String, CodingKey {
        case identity
        case id
        case name
        case repo
        case color
        case path
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let repoName = try? container.decode(String.self) {
            self.init(identity: repoName, name: repoName)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let identity = try container.decodeIfPresent(String.self, forKey: .identity)
            ?? container.decodeIfPresent(String.self, forKey: .id)
            ?? container.decodeIfPresent(String.self, forKey: .repo)
            ?? container.decodeIfPresent(String.self, forKey: .name)
            ?? ""
        let name = try container.decodeIfPresent(String.self, forKey: .name)
            ?? container.decodeIfPresent(String.self, forKey: .repo)
            ?? identity
        let color = try container.decodeIfPresent(String.self, forKey: .color) ?? ""
        let path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        self.init(identity: identity, name: name, color: color, path: path)
    }
}

private struct LossyArray<Element: Decodable>: Decodable {
    var elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var decoded: [Element] = []

        while !container.isAtEnd {
            do {
                decoded.append(try container.decode(Element.self))
            } catch {
                fputs("Questmaster: skipped bad \(Element.self) in serve payload: \(error)\n", stderr)
                _ = try? container.decode(DiscardedJSONValue.self)
            }
        }

        elements = decoded
    }
}

private struct DiscardedJSONValue: Decodable {
    init(from decoder: Decoder) throws {
        if var array = try? decoder.unkeyedContainer() {
            while !array.isAtEnd {
                _ = try? array.decode(DiscardedJSONValue.self)
            }
            return
        }

        if let object = try? decoder.container(keyedBy: DynamicCodingKey.self) {
            for key in object.allKeys {
                _ = try? object.decode(DiscardedJSONValue.self, forKey: key)
            }
            return
        }

        let scalar = try decoder.singleValueContainer()
        if scalar.decodeNil() {
            return
        }
        if (try? scalar.decode(Bool.self)) != nil {
            return
        }
        if (try? scalar.decode(Double.self)) != nil {
            return
        }
        _ = try? scalar.decode(String.self)
    }
}

private struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

private extension KeyedDecodingContainer {
    func decodeLossyArray<Element: Decodable>(_ type: Element.Type, forKey key: Key) -> [Element] {
        (try? decode(LossyArray<Element>.self, forKey: key).elements) ?? []
    }
}
