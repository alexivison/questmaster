import Foundation
import QuestmasterCore

struct PullRequestStoreTests {
    static func run() {
        requestBuilder()
        selectionRevisionAndVisibilityPulls()
        oneInFlightQueuesOneFollowUp()
        oldSelectionResponseIsDropped()
        failureKeepsRowsAndShowsNotice()
        unchangedSyncKeepsDisplayRowsBuffer()
        emptyRevisionSkipsPullAndClearsRows()
        cursorStartsFirstMovesAndClamps()
        cursorFollowsItsRowAndFallsBack()
        commandsBuildEffects()
        unwatchedFollowsTheRevision()
        refreshFailureKeepsRowsAndShowsNotice()
        print("PullRequestStoreTests: all tests passed")
    }

    private static func requestBuilder() {
        let store = PullRequestStore()
        let request = store.sync(selectedSessionID: "master", sessions: [session("master", rev: "1")], isVisible: true)!
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
        let sessions = [session("master", rev: "1"), session("worker", role: "worker", rev: "1")]
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

    private static func unchangedSyncKeepsDisplayRowsBuffer() {
        let store = PullRequestStore()
        let selected = session("master", rev: "1")
        let request = store.sync(selectedSessionID: "master", sessions: [selected], isVisible: true)!
        _ = store.apply(response: [PullRequestModelsTests.row(1)], for: request)
        let original = store.displayRows
        let originalBuffer = original.withUnsafeBufferPointer(\.baseAddress)
        expect(store.sync(selectedSessionID: "master", sessions: [selected], isVisible: true) == nil, "unchanged sync should not pull")
        expect(store.displayRows.withUnsafeBufferPointer(\.baseAddress) == originalBuffer, "unchanged sync should keep the display row buffer")
    }

    private static func emptyRevisionSkipsPullAndClearsRows() {
        let store = PullRequestStore()
        expect(store.sync(selectedSessionID: "master", sessions: [session("master")], isVisible: true) == nil, "empty revision should not pull")
        let request = store.sync(selectedSessionID: "master", sessions: [session("master", rev: "1")], isVisible: true)!
        _ = store.apply(response: [PullRequestModelsTests.row(1)], for: request)
        expect(store.rows.count == 1, "nonempty revision should load a row")
        expect(store.sync(selectedSessionID: "master", sessions: [session("master")], isVisible: true) == nil, "unwatching last PR should not pull")
        expect(store.rows.isEmpty && store.displayRows.isEmpty, "unwatching last PR should clear rows")
    }

    private static func loadedStore(_ numbers: [Int]) -> PullRequestStore {
        let store = PullRequestStore()
        let request = store.sync(selectedSessionID: "master", sessions: [session("master", rev: "1")], isVisible: true)!
        _ = store.apply(response: numbers.map { PullRequestModelsTests.row($0, status: PullRequestModelsTests.status(updated: "2026-06-\(10 + $0)T00:00:00Z")) }, for: request)
        return store
    }

    /// Newest first, so row 3 sorts first.
    private static func cursorStartsFirstMovesAndClamps() {
        let store = loadedStore([1, 2, 3])
        expect(store.cursorKey?.hasSuffix("#3") == true, "the cursor starts on the first row")
        _ = store.handle(.move(1))
        expect(store.cursorKey?.hasSuffix("#2") == true, "down moves to the next row")
        _ = store.handle(.move(5))
        expect(store.cursorKey?.hasSuffix("#1") == true, "down clamps at the last row")
        _ = store.handle(.move(-5))
        expect(store.cursorKey?.hasSuffix("#3") == true, "up clamps at the first row")
        store.setCursor(store.displayRows[1].pullRequest.key)
        expect(store.cursorKey?.hasSuffix("#2") == true, "a click picks its row")
        store.setCursor("github.com/owner/repo#999")
        expect(store.cursorKey?.hasSuffix("#2") == true, "a click on a row that's gone changes nothing")
        let empty = PullRequestStore()
        _ = empty.handle(.move(1))
        expect(empty.cursorKey == nil, "no rows, no cursor")
    }

    private static func cursorFollowsItsRowAndFallsBack() {
        let store = loadedStore([1, 2, 3])
        _ = store.handle(.move(1))
        let picked = store.cursorKey
        let request = store.sync(selectedSessionID: "master", sessions: [session("master", rev: "2")], isVisible: true)!
        let newest = PullRequestModelsTests.row(2, status: PullRequestModelsTests.status(updated: "2026-07-01T00:00:00Z"))
        _ = store.apply(response: [PullRequestModelsTests.row(1), newest, PullRequestModelsTests.row(3)], for: request)
        expect(store.displayRows.first?.pullRequest.key == picked && store.cursorKey == picked, "the cursor follows its row through a re-sort")
        let gone = store.sync(selectedSessionID: "master", sessions: [session("master", rev: "3")], isVisible: true)!
        _ = store.apply(response: [PullRequestModelsTests.row(1)], for: gone)
        expect(store.cursorKey == store.displayRows.first?.pullRequest.key, "a vanished row's cursor falls back to the first row")
        let other = store.sync(selectedSessionID: "worker", sessions: [session("master", rev: "3"), session("worker", role: "worker", rev: "1")], isVisible: true)!
        expect(store.cursorKey == nil && other.sessionID == "worker", "a new selection clears the cursor")
    }

    private static func commandsBuildEffects() {
        let store = loadedStore([1, 2])
        let url = URL(string: "https://github.com/Owner/Repo/pull/2")!
        expect(store.handle(.open) == .open(url), "open takes the cursor row's page")
        expect(store.handle(.copyURL) == .copy(url), "copy takes the cursor row's page")
        expect(store.handle(.move(1)) == nil, "moving builds no effect")
        guard case .refresh(let request)? = store.handle(.refresh) else {
            expect(false, "refresh scopes to the selected session")
            return
        }
        expect(request.sessionID == "master", "refresh scopes to the selected session")
        let object = request.jsonObject(id: "r-1")
        let data = object["data"] as? [String: Any]
        expect(object["method"] as? String == "pr.refresh" && object["id"] as? String == "r-1", "refresh method and id")
        expect(data?["session_id"] as? String == "master" && data?["wait"] as? Bool == false, "refresh scope and no waiting")
        let empty = PullRequestStore()
        expect(empty.handle(.open) == nil && empty.handle(.copyURL) == nil && empty.handle(.refresh) == nil, "nothing selected, nothing to do")
    }

    private static func unwatchedFollowsTheRevision() {
        let store = PullRequestStore()
        expect(store.isUnwatched, "no session is unwatched")
        _ = store.sync(selectedSessionID: "master", sessions: [session("master")], isVisible: true)
        expect(store.isUnwatched, "an empty revision is unwatched")
        _ = store.sync(selectedSessionID: "master", sessions: [session("master", rev: "1")], isVisible: true)
        expect(!store.isUnwatched, "a revision means pull requests are watched, even before they load")
        _ = store.sync(selectedSessionID: "master", sessions: [session("master")], isVisible: true)
        expect(store.isUnwatched, "unwatching the last one shows the empty state")
    }

    private static func refreshFailureKeepsRowsAndShowsNotice() {
        let store = loadedStore([1])
        store.failRefresh()
        expect(store.rows.count == 1 && store.readNotice == "Couldn't refresh pull requests", "a refused refresh keeps the rows and says so")
        let request = store.sync(selectedSessionID: "master", sessions: [session("master", rev: "2")], isVisible: true)!
        _ = store.apply(response: [PullRequestModelsTests.row(1)], for: request)
        expect(store.readNotice == nil, "the next pull clears the notice")
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
