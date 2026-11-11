import Foundation

/// The Quest Log's list filter: the text, and the type and size tags it keeps. Within a group any selected tag
/// matches (OR); the text and each group must match (AND).
public struct QuestListFilter: Equatable {
    public var text: String
    public var types: Set<String>
    public var sizes: Set<String>

    public init(text: String = "", types: Set<String> = [], sizes: Set<String> = []) {
        self.text = text
        self.types = types
        self.sizes = sizes
    }

    public func matches(_ quest: QuestItem) -> Bool {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchesText = cleanText.isEmpty || quest.content.localizedCaseInsensitiveContains(cleanText)
        let matchesType = types.isEmpty || quest.types.contains(where: types.contains)
        let matchesSize = sizes.isEmpty || sizes.contains(quest.size)
        return matchesText && matchesType && matchesSize
    }
}

/// A project tab: one per project that has quests. The tab's ID is the project ID.
public struct QuestProjectTab: Equatable, Identifiable {
    public var projectID: String
    public var title: String

    public var id: String { projectID }

    public init(projectID: String, title: String) {
        self.projectID = projectID
        self.title = title
    }
}

public enum QuestDisplayState {
    /// The project tabs after All: one per project that has quests, in the user's project order. Quests without a
    /// project have no tab.
    public static func projectTabs(quests: [QuestItem], repos: [TrackerRepo], projects: [TrackerProject]) -> [QuestProjectTab] {
        let tabs = projectTitles(quests: quests, repos: repos, projects: projects).map {
            QuestProjectTab(projectID: $0.key, title: $0.value)
        }
        return ProjectOrder(projects: projects).sorted(tabs, id: \.projectID, title: \.title)
    }

    /// The name each project with quests shows, keyed by project ID. Quests without a project are left out.
    public static func projectTitles(quests: [QuestItem], repos: [TrackerRepo], projects: [TrackerProject]) -> [String: String] {
        let repoByID = Dictionary(uniqueKeysWithValues: repos.map { ($0.id, $0) })
        let order = ProjectOrder(projects: projects)
        var titles: [String: String] = [:]
        for quest in quests {
            guard let projectID = projectKey(of: quest), titles[projectID] == nil else {
                continue
            }
            titles[projectID] = sectionTitle(repoByID[projectID], order.project(for: projectID), quest)
        }
        return titles
    }

    /// The chips a quest's row shows: its size, then its types in `QuestTagType` order. Tags outside those sets show nothing.
    public static func tagChipNames(for quest: QuestItem) -> [String] {
        let size = QuestSize(rawValue: quest.size).map { [$0.rawValue] } ?? []
        let types = QuestTagType.allCases.filter { quest.types.contains($0.rawValue) }.map(\.displayName)
        return size + types
    }

    /// The quests the list shows: those in the tab's project (nil for All) that pass the filter, newest created first.
    public static func visibleQuests(quests: [QuestItem], filter: QuestListFilter, projectID: String?) -> [QuestItem] {
        quests
            .filter { quest in
                (projectID == nil || projectKey(of: quest) == projectID) && filter.matches(quest)
            }
            .sorted(by: isNewerFirst)
    }

    /// The quest the selection should move to when `current` leaves the list: the nearest one above it that is still
    /// listed, else the first quest.
    public static func recoveredSelection(
        current id: String?,
        in quests: [QuestItem],
        previouslyDisplayedQuests: [QuestItem] = []
    ) -> String? {
        guard !quests.isEmpty else {
            return nil
        }
        if let id, quests.contains(where: { $0.id == id }) {
            return id
        }
        let visibleIDs = Set(quests.map(\.id))
        if let id,
           let index = previouslyDisplayedQuests.firstIndex(where: { $0.id == id }),
           let previous = previouslyDisplayedQuests[..<index].last(where: { quest in
               visibleIDs.contains(quest.id)
           }) {
            return previous.id
        }
        return quests[0].id
    }

    public static func movedSelection(current id: String?, delta: Int, in quests: [QuestItem]) -> String? {
        guard !quests.isEmpty else {
            return nil
        }
        let currentIndex = id.flatMap { current in quests.firstIndex { $0.id == current } } ?? 0
        return quests[wrapped(currentIndex + delta, count: quests.count)].id
    }

    /// The first (`atStart`) or last quest, for the `gg`/`G` jump shortcuts.
    public static func edgeSelection(atStart: Bool, in quests: [QuestItem]) -> String? {
        atStart ? quests.first?.id : quests.last?.id
    }

    /// Newest created first, so editing a quest doesn't move it; ties by id.
    private static func isNewerFirst(_ lhs: QuestItem, _ rhs: QuestItem) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt
        }
        return lhs.id < rhs.id
    }

    /// The quest's project ID, nil when it has none.
    static func projectKey(of quest: QuestItem) -> String? {
        clean(quest.projectID)
    }

    private static func title(for quest: QuestItem) -> String {
        clean(quest.projectName) ?? clean(quest.projectPath).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Unknown Project"
    }

    /// The project's effective name when the snapshot lists the project, then the repo's, then what the quest stored.
    private static func sectionTitle(_ repo: TrackerRepo?, _ project: TrackerProject?, _ quest: QuestItem) -> String {
        if let project {
            return clean(project.name) ?? project.id
        }
        if let repo {
            return clean(repo.name) ?? repo.id
        }
        return title(for: quest)
    }

    private static func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

private func wrapped(_ index: Int, count: Int) -> Int {
    if index < 0 {
        return count - 1
    }
    if index >= count {
        return 0
    }
    return index
}
