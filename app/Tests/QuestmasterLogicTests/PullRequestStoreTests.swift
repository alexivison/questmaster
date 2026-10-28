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
        cursorJumpsToTheEdges()
        cursorFollowsItsRowAndFallsBack()
        commandsBuildEffects()
        unwatchedFollowsTheRevision()
        refreshFailureKeepsRowsAndShowsNotice()
        refreshSpinnerFollowsTheKeyAndTheReply()
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

    /// gg and G go to the first and last row, the same as the lists' keys.
    private static func cursorJumpsToTheEdges() {
        let store = loadedStore([1, 2, 3])
        _ = store.handle(.jumpToBottom)
        expect(store.cursorKey?.hasSuffix("#1") == true, "G should go to the last row")
        _ = store.handle(.jumpToTop)
        expect(store.cursorKey?.hasSuffix("#3") == true, "gg should go to the first row")
        let empty = PullRequestStore()
        _ = empty.handle(.jumpToBottom)
        expect(empty.cursorKey == nil, "no rows, no cursor to jump")
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
        expect(data?["session_id"] as? String == "master" && data?["wait"] as? Bool == true, "refresh scope, and the daemon replies once it has refreshed")
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
        guard case .refresh(let refresh)? = store.handle(.refresh) else {
            expect(false, "r should ask for a refresh")
            return
        }
        store.finishRefresh(refresh, failed: true)
        expect(store.rows.count == 1 && store.readNotice == "Couldn't refresh pull requests", "a refused refresh keeps the rows and says so")
        let request = store.sync(selectedSessionID: "master", sessions: [session("master", rev: "2")], isVisible: true)!
        _ = store.apply(response: [PullRequestModelsTests.row(1)], for: request)
        expect(store.readNotice == nil, "the next pull clears the notice")
    }

    /// The refresh spinner: `r` starts it, the daemon's reply (or its refusal) ends it, but not before one turn has shown;
    /// no reply at all ends it at the cap; a second `r` while one runs sends nothing; a reply to a refresh that has ended,
    /// or to another session's, is ignored.
    private static func refreshSpinnerFollowsTheKeyAndTheReply() {
        let start = Date(timeIntervalSince1970: 1_000)
        func after(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }
        func begin(_ store: PullRequestStore, at time: Date = start) -> PullRequestRefreshRequest {
            guard case .refresh(let request)? = store.handle(.refresh, now: time) else {
                fatalError("r should ask for a refresh")
            }
            return request
        }

        let store = loadedStore([1])
        expect(!store.isRefreshing, "nothing refreshes until r")
        let first = begin(store)
        expect(store.isRefreshing, "r starts the spinner")
        expect(store.handle(.refresh, now: after(0.5)) == nil && store.isRefreshing, "a second r while one runs sends no second request")
        expect(store.settleRefresh(now: after(5)) == PullRequestStore.refreshCap - 5, "with no reply yet, the cap is what's left to wait for")
        expect(store.isRefreshing, "and it keeps spinning meanwhile")

        let quick = store.finishRefresh(first, failed: false, now: after(0.2))
        expect(store.isRefreshing && quick != nil && abs(quick! - (WorkingSpinner.period - 0.2)) < 0.0001, "a quick reply keeps the spinner for the rest of one turn, got \(String(describing: quick))")
        expect(store.settleRefresh(now: after(1.1)) != nil && store.isRefreshing, "still short of a full turn")
        expect(store.settleRefresh(now: after(WorkingSpinner.period)) == nil && !store.isRefreshing, "a full turn after the key, it ends")
        expect(store.readNotice == nil, "an answered refresh says nothing")

        let slow = begin(store, at: after(10))
        expect(store.finishRefresh(slow, failed: false, now: after(14)) == nil && !store.isRefreshing, "a reply after the turn ends it at once")

        let refused = begin(store, at: after(20))
        expect(store.finishRefresh(refused, failed: true, now: after(23)) == nil && !store.isRefreshing, "a refusal ends it too")
        expect(store.readNotice == "Couldn't refresh pull requests", "and says so")

        let lost = begin(store, at: after(30))
        expect(store.settleRefresh(now: after(30 + PullRequestStore.refreshCap - 1)) == 1 && store.isRefreshing, "no reply, short of the cap: still spinning")
        expect(store.settleRefresh(now: after(30 + PullRequestStore.refreshCap)) == nil && !store.isRefreshing, "no reply by the cap: it gives up")
        expect(store.finishRefresh(lost, failed: false, now: after(100)) == nil, "a reply after the cap changes nothing")

        let stale = begin(store, at: after(200))
        _ = store.finishRefresh(stale, failed: false, now: after(205))
        let next = begin(store, at: after(210))
        expect(store.finishRefresh(stale, failed: false, now: after(211)) == nil && store.isRefreshing, "an earlier request's reply doesn't end the current refresh")
        expect(next != stale, "each refresh is its own request")

        _ = store.sync(selectedSessionID: "worker", sessions: [session("master", rev: "3"), session("worker", role: "worker", rev: "1")], isVisible: true)
        expect(!store.isRefreshing, "another session's dock isn't refreshing")
        expect(store.finishRefresh(next, failed: true, now: after(212)) == nil && store.readNotice == nil, "and the old session's reply is ignored")
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
