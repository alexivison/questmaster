import Foundation

/// The chips a master plate shows: merge conflicts first, since they need action, then the git states in order. Totals come
/// from the daemon's live Watcher scope, where a conflicting open or draft PR counts only under conflicts.
public struct TrackerPullRequestBadge: Equatable {
    public enum Kind: Hashable {
        case conflicts
        case state(PullRequestGitState)
    }

    public let kind: Kind
    public let count: Int

    public var countLabel: String { count > 9 ? "+" : "\(count)" }
    public var tooltip: String {
        let noun = "pull request\(count == 1 ? "" : "s")"
        switch kind {
        case .conflicts: return "\(count) \(noun) with merge conflicts"
        case .state(let state): return "\(count) \(String(describing: state)) \(noun)"
        }
    }

    public static func make(for session: TrackerSession) -> [Self] {
        guard SessionRoleKind(role: session.role) == .master else { return [] }
        let counts = session.pullRequestCounts
        let totals: [(Kind, Int)] = [
            (.conflicts, counts.conflicts),
            (.state(.open), counts.open), (.state(.draft), counts.draft),
            (.state(.merged), counts.merged), (.state(.closed), counts.closed),
        ]
        return totals.compactMap { kind, count in
            count > 0 ? Self(kind: kind, count: count) : nil
        }
    }
}
