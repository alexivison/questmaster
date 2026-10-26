import Foundation
import QuestmasterCore

struct PullRequestStoreTests {
    static func run() {
        requestBuilder()
        selectionRevisionAndVisibilityPulls()
        oneInFlightQueuesOneFollowUp()
        oldSelectionResponseIsDropped()
        failureKeepsRowsAndShowsNotice()
        print("PullRequestStoreTests: all tests passed")
    }

    private static func requestBuilder() {
        let store = PullRequestStore()
        let request = store.sync(selectedSessionID: "master", sessions: [session("master")], isVisible: true)!
        let object = request.jsonObject(id: "pull-1")
        expect(object["id"] as? String == "pull-1", "request id")
        expect(object["method"] as? String == "pull_requests", "request method")
        expect((object["data"] as? [String: String])?["session_id"] == "master", "request scope")
    }

    private static func selectionRevisionAndVisibilityPulls() {
        let store = PullRequestStore()
        let master = session("master", rev: "1")
        let worker = session("worker", role: "worker", rev: "1")
        expect(store.sync(selectedSessionID: "master", sessions: [master, worker], isVisible: false) == nil, "hidden dock should not pull")
        let first = store.sync(selectedSessionID: "master", sessions: [master, worker], isVisible: true)!
        expect(first.sessionID == "master" && first.revision == "1", "visible dock should pull selected session")
        expect(store.apply(response: [], for: first) == nil, "completed pull has no follow-up")
        expect(store.sync(selectedSessionID: "master", sessions: [master, worker], isVisible: true) == nil, "unchanged revision should not pull")

        let changed = session("master", rev: "2")
        let revisionPull = store.sync(selectedSessionID: "master", sessions: [changed, worker], isVisible: true)!
        expect(revisionPull.revision == "2", "changed revision should pull")
        _ = store.apply(response: [], for: revisionPull)
        let selectionPull = store.sync(selectedSessionID: "worker", sessions: [changed, worker], isVisible: true)!
        expect(selectionPull.sessionID == "worker", "selection change should pull")
        _ = store.apply(response: [], for: selectionPull)
        expect(store.sync(selectedSessionID: "worker", sessions: [changed, worker], isVisible: false) == nil, "hidden dock should not pull")
        expect(store.sync(selectedSessionID: "worker", sessions: [changed, worker], isVisible: true) != nil, "reopening dock should pull")
    }

    private static func oneInFlightQueuesOneFollowUp() {
        let store = PullRequestStore()
        let first = store.sync(selectedSessionID: "master", sessions: [session("master", rev: "1")], isVisible: true)!
        expect(store.sync(selectedSessionID: "master", sessions: [session("master", rev: "2")], isVisible: true) == nil, "second pull must wait")
        expect(store.sync(selectedSessionID: "master", sessions: [session("master", rev: "3")], isVisible: true) == nil, "further changes coalesce")
        let followUp = store.apply(response: [PullRequestModelsTests.row(1)], for: first)!
        expect(followUp.revision == "3", "follow-up should use latest revision")
        expect(store.rows.isEmpty, "old revision response should be dropped")
        expect(store.apply(response: [PullRequestModelsTests.row(2)], for: followUp) == nil, "only one follow-up should run")
        expect(store.rows.map(\.number) == [2], "latest response should apply")
    }

    private static func oldSelectionResponseIsDropped() {
        let store = PullRequestStore()
        let sessions = [session("master"), session("worker", role: "worker")]
        let old = store.sync(selectedSessionID: "master", sessions: sessions, isVisible: true)!
        expect(store.sync(selectedSessionID: "worker", sessions: sessions, isVisible: true) == nil, "new selection waits for in-flight pull")
        let next = store.apply(response: [PullRequestModelsTests.row(1)], for: old)!
        expect(store.rows.isEmpty && next.sessionID == "worker", "old selection response should be dropped")
        _ = store.apply(response: [PullRequestModelsTests.row(2)], for: next)
        expect(store.rows.map(\.number) == [2], "new selection response should apply")
    }

    private static func failureKeepsRowsAndShowsNotice() {
        let store = PullRequestStore()
        let first = store.sync(selectedSessionID: "master", sessions: [session("master", rev: "1")], isVisible: true)!
        _ = store.apply(response: [PullRequestModelsTests.row(1)], for: first)
        let changed = store.sync(selectedSessionID: "master", sessions: [session("master", rev: "2")], isVisible: true)!
        expect(store.fail(error: Failure(), for: changed) == nil, "failure with no intervening change has no immediate retry")
        expect(store.rows.map(\.number) == [1], "failure should keep prior rows")
        expect(store.readNotice != nil, "failure should show muted notice")
        expect(store.sync(selectedSessionID: "master", sessions: [session("master", rev: "2")], isVisible: true) == nil, "unchanged revision should not spin on failure")
        let retry = store.sync(selectedSessionID: "master", sessions: [session("master", rev: "3")], isVisible: true)!
        _ = store.apply(response: [], for: retry)
        expect(store.readNotice == nil, "successful pull clears notice")
    }

    private static func session(_ id: String, role: String = "master", rev: String = "") -> TrackerSession {
        TrackerSession(id: id, title: id, repoName: "repo", role: role, pullRequestsRev: rev)
    }

    private struct Failure: Error {}

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("PullRequestStoreTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
