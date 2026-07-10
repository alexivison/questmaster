import Foundation

public struct QuestSection: Equatable, Identifiable {
    public var id: String
    public var title: String
    public var color: String
    public var quests: [QuestItem]

    public init(id: String, title: String, color: String = "", quests: [QuestItem]) {
        self.id = id
        self.title = title
        self.color = color
        self.quests = quests
    }
}

public enum QuestDisplayState {
    public static func sections(
        quests: [QuestItem],
        repos: [TrackerRepo],
        projects: [TrackerProject] = [],
        scope: QuestScope,
        query: String = "",
        projectID: String? = nil,
        projectIDs: Set<String> = []
    ) -> [QuestSection] {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var cleanProjectIDs = Set(projectIDs.compactMap(clean))
        if let cleanProjectID = clean(projectID) {
            cleanProjectIDs.insert(cleanProjectID)
        }
        let visible = quests.filter { quest in
            quest.done == (scope == .done)
                && (cleanProjectIDs.isEmpty || cleanProjectIDs.contains(quest.projectID))
                && (cleanQuery.isEmpty || quest.content.localizedCaseInsensitiveContains(cleanQuery))
        }
        guard !visible.isEmpty else {
            return []
        }

        let grouped = Dictionary(grouping: visible) { clean($0.projectID) ?? "" }
        let repoByID = Dictionary(uniqueKeysWithValues: repos.map { ($0.id, $0) })
        let projectByID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        var out: [QuestSection] = []

        let sortedProjectIDs = grouped.keys
            .filter { !$0.isEmpty }
            .sorted { lhs, rhs in
                sectionTitle(repoByID[lhs], projectByID[lhs], grouped[lhs]?.first).localizedCaseInsensitiveCompare(
                    sectionTitle(repoByID[rhs], projectByID[rhs], grouped[rhs]?.first)
                ) == .orderedAscending
            }
        for id in sortedProjectIDs {
            let repo = repoByID[id]
            let project = projectByID[id]
            out.append(QuestSection(
                id: id,
                title: sectionTitle(repo, project, grouped[id]?.first),
                color: repo?.color ?? project?.color ?? "",
                quests: sorted(grouped[id] ?? [])
            ))
        }

        if let noProject = grouped[""], !noProject.isEmpty {
            out.append(QuestSection(id: "no-project", title: "No project", quests: sorted(noProject)))
        }
        return out
    }

    public static func flatQuests(in sections: [QuestSection]) -> [QuestItem] {
        sections.flatMap(\.quests)
    }

    public static func recoveredSelection(current id: String?, in sections: [QuestSection]) -> String? {
        let quests = flatQuests(in: sections)
        guard !quests.isEmpty else {
            return nil
        }
        if let id, quests.contains(where: { $0.id == id }) {
            return id
        }
        return quests[0].id
    }

    public static func movedSelection(current id: String?, delta: Int, in sections: [QuestSection]) -> String? {
        let quests = flatQuests(in: sections)
        guard !quests.isEmpty else {
            return nil
        }
        let currentIndex = id.flatMap { current in quests.firstIndex { $0.id == current } } ?? 0
        return quests[wrapped(currentIndex + delta, count: quests.count)].id
    }

    public static func movedScope(current: QuestScope, delta: Int) -> QuestScope {
        let scopes = QuestScope.allCases
        guard let index = scopes.firstIndex(of: current) else {
            return current
        }
        return scopes[wrapped(index + delta, count: scopes.count)]
    }

    private static func sorted(_ quests: [QuestItem]) -> [QuestItem] {
        quests.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.id < rhs.id
        }
    }

    private static func title(for quest: QuestItem?) -> String {
        clean(quest?.projectName) ?? clean(quest?.projectPath).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Unknown Project"
    }

    private static func sectionTitle(_ repo: TrackerRepo?, _ project: TrackerProject?, _ quest: QuestItem?) -> String {
        if let repo {
            return clean(repo.name) ?? repo.id
        }
        if let project {
            return clean(project.name) ?? project.id
        }
        return title(for: quest)
    }

    private static func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

private func wrapped(_ index: Int, count: Int) -> Int {
    guard count > 0 else {
        return 0
    }
    if index < 0 {
        return count - 1
    }
    if index >= count {
        return 0
    }
    return index
}
