import Foundation

/// The chips a master plate shows, in git-state order. Totals come from the daemon's live Watcher scope.
public struct TrackerPullRequestBadge: Equatable {
    public let state: PullRequestGitState
    public let count: Int

    public var countLabel: String { count > 9 ? "+" : "\(count)" }
    public var tooltip: String {
        "\(count) \(String(describing: state)) pull request\(count == 1 ? "" : "s")"
    }

    public static func make(for session: TrackerSession) -> [Self] {
        guard SessionRoleKind(role: session.role) == .master else { return [] }
        let counts = session.pullRequestCounts
        let totals: [(PullRequestGitState, Int)] = [
            (.open, counts.open), (.draft, counts.draft), (.merged, counts.merged), (.closed, counts.closed),
        ]
        return totals.compactMap { state, count in
            count > 0 ? Self(state: state, count: count) : nil
        }
    }
}
