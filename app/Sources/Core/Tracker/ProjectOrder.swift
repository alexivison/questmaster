import Foundation

/// The user's project order. The tracker snapshot lists `projects` in that order, so a project's rank is its
/// position there. A project the snapshot doesn't list, and the empty ID, rank after every listed one.
public struct ProjectOrder {
    private let projectsByID: [String: TrackerProject]
    private let ranks: [String: Int]

    public init(projects: [TrackerProject]) {
        var projectsByID: [String: TrackerProject] = [:]
        var ranks: [String: Int] = [:]
        for (index, project) in projects.enumerated() where ranks[project.id] == nil {
            projectsByID[project.id] = project
            ranks[project.id] = index
        }
        self.projectsByID = projectsByID
        self.ranks = ranks
    }

    /// Where a project sorts. An unlisted or empty ID gets the same last rank.
    public func rank(of id: String) -> Int {
        ranks[id] ?? Int.max
    }

    /// The snapshot's project for an ID, nil when the snapshot doesn't list one.
    public func project(for id: String) -> TrackerProject? {
        projectsByID[id]
    }

    /// Items in the user's order by project ID. Items that rank the same (unlisted projects) sort by title, then ID.
    public func sorted<Item>(_ items: [Item], id: (Item) -> String, title: (Item) -> String) -> [Item] {
        items.sorted { lhs, rhs in
            let lhsRank = rank(of: id(lhs))
            let rhsRank = rank(of: id(rhs))
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            let titleOrder = title(lhs).localizedCaseInsensitiveCompare(title(rhs))
            if titleOrder != .orderedSame {
                return titleOrder == .orderedAscending
            }
            return id(lhs) < id(rhs)
        }
    }
}
