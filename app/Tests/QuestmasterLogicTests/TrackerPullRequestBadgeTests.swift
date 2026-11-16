import Foundation
import QuestmasterCore

struct TrackerPullRequestBadgeTests {
    static func run() {
        var session = TrackerSession(id: "preview-master", title: "Example", repoName: "Example", role: "master")
        expect(TrackerPullRequestBadge.make(for: session).isEmpty, "a master without watched PRs has no chips")
        session.pullRequestCounts = PullRequestCounts(merged: 2)
        var badges = TrackerPullRequestBadge.make(for: session)
        expect(badges.map(\.state) == [.merged] && badges.map(\.count) == [2], "merged-only masters have one chip")
        session.pullRequestCounts = PullRequestCounts(open: 1, draft: 4, merged: 2, closed: 3)
        badges = TrackerPullRequestBadge.make(for: session)
        expect(badges.map(\.state) == [.open, .draft, .merged, .closed], "chips follow the git-state order")
        expect(badges.map(\.count) == [1, 4, 2, 3], "chips preserve the daemon's master and worker totals")
        session.pullRequestCounts = PullRequestCounts(open: 1, draft: 4)
        expect(TrackerPullRequestBadge.make(for: session).map(\.state) == [.open, .draft], "zero states have no chip")
        session.pullRequestCounts = PullRequestCounts()
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
