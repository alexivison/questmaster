import Foundation

/// The Projects list's cursor: the highlighted row's index, held inside the rows the list shows.
public enum ProjectListCursor {
    /// `index` one step on by `delta` (+1 down, -1 up), held inside a list of `count` rows.
    public static func moved(from index: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else {
            return 0
        }
        return min(max(index + delta, 0), count - 1)
    }
}

/// Arrange mode's local copy of the project order. Moves change only this copy; `reorderRequest` sends it whole.
public struct ProjectArrangement: Equatable {
    /// The project IDs in the order being arranged.
    public private(set) var projectIDs: [String]
    /// The order arranging started from.
    private let savedIDs: [String]
    /// The highlighted row. A move carries it along, so the row stays highlighted where it lands.
    public private(set) var highlight: Int

    public init(projectIDs: [String], highlight: Int) {
        self.projectIDs = projectIDs
        savedIDs = projectIDs
        self.highlight = ProjectListCursor.moved(from: highlight, by: 0, count: projectIDs.count)
    }

    /// Whether the order differs from the one arranging started from.
    public var isDirty: Bool {
        projectIDs != savedIDs
    }

    /// Swaps the highlighted row with its neighbour one step on. At either end it does nothing.
    public mutating func moveHighlightedRow(by delta: Int) {
        let target = ProjectListCursor.moved(from: highlight, by: delta, count: projectIDs.count)
        guard target != highlight else {
            return
        }
        projectIDs.swapAt(highlight, target)
        highlight = target
    }

    /// Moves the highlight to `index`, held inside the rows.
    public mutating func setHighlight(_ index: Int) {
        highlight = ProjectListCursor.moved(from: index, by: 0, count: projectIDs.count)
    }

    /// The snapshot's projects in the arranged order. A project the snapshot no longer lists drops out.
    public func projects(from projects: [TrackerProject]) -> [TrackerProject] {
        let byID = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return projectIDs.compactMap { byID[$0] }
    }

    /// The reorder Save sends, or nil when nothing moved (Save then just leaves arrange mode).
    public func reorderRequest() throws -> ServeMutationRequest? {
        guard isDirty else {
            return nil
        }
        return try ServeMutationRequests.projectReorder(projectIDs: projectIDs)
    }
}
