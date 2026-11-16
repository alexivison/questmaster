import Foundation
import QuestmasterCore

struct TrackerPullRequestBadgeTests {
    static func run() {
        var session = TrackerSession(id: "preview-master", title: "Example", repoName: "Example", role: "master")
        expect(TrackerPullRequestBadge.make(for: session).isEmpty, "a master without watched PRs has no chips")
        session.pullRequestCounts = PullRequestCounts(merged: 2)
        var badges = TrackerPullRequestBadge.make(for: session)
        expect(badges.map(\.kind) == [.state(.merged)] && badges.map(\.count) == [2], "merged-only masters have one chip")
        session.pullRequestCounts = PullRequestCounts(conflicts: 5, open: 1, draft: 4, merged: 2, closed: 3)
        badges = TrackerPullRequestBadge.make(for: session)
        expect(badges.map(\.kind) == [.conflicts, .state(.open), .state(.draft), .state(.merged), .state(.closed)], "conflicts lead, then the git-state order")
        expect(badges.map(\.count) == [5, 1, 4, 2, 3], "chips preserve the daemon's master and worker totals")
        expect(badges.first?.tooltip == "5 pull requests with merge conflicts", "the conflicts chip names conflicts")
        session.pullRequestCounts = PullRequestCounts(conflicts: 1)
        expect(TrackerPullRequestBadge.make(for: session).first?.tooltip == "1 pull request with merge conflicts", "one conflict is singular")
        session.pullRequestCounts = PullRequestCounts(open: 1, draft: 4)
        expect(TrackerPullRequestBadge.make(for: session).map(\.kind) == [.state(.open), .state(.draft)], "zero states have no chip")
        for (count, label) in [(9, "9"), (10, "+")] {
            session.pullRequestCounts = PullRequestCounts(open: count)
            let badge = TrackerPullRequestBadge.make(for: session).first
            expect(badge?.countLabel == label, "\(count) should display \(label) without shrinking")
            expect(badge?.tooltip == "\(count) open pull requests", "the tooltip should preserve the exact count")
        }
        session.pullRequestCounts = PullRequestCounts(open: 0)
        expect(TrackerPullRequestBadge.make(for: session).isEmpty, "ending the last watch removes the chips")
        session.pullRequestCounts = PullRequestCounts(open: 3)
        for role in ["worker", "shell", "tmux", "orphan"] {
            session.role = role
            expect(TrackerPullRequestBadge.make(for: session).isEmpty, "\(role) rows never show chips")
        }
        print("TrackerPullRequestBadgeTests: all tests passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("TrackerPullRequestBadgeTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
