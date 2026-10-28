import Foundation
import QuestmasterCore

struct PullRequestModelsTests {
    static func run() {
        unknownWireValuesDecode()
        watcherTagsUseWorkerTitles()
        rowsSortByStateThenDateThenKey()
        looksStaySeparate()
        labelsFormatEveryField()
        gitStateSeparatesDraftFromOpen()
        urlFallsBackToTheRefAndStaysWeb()
        looksDimStaleRowsAndWarnInaccessibleOnes()
        print("PullRequestModelsTests: all tests passed")
    }

    private static func unknownWireValuesDecode() {
        let value = row(1, status: status(state: "future", review: "future", ci: "future", reason: "future"))
        expect(value.status?.state == .unknown, "unknown state should decode")
        expect(value.status?.review == .unknown, "unknown review should decode")
        expect(value.status?.ci == .unknown, "unknown CI should decode")
        expect(value.status?.inaccessibleReason == .unknown, "unknown inaccessible reason should decode")
    }

    private static func watcherTagsUseWorkerTitles() {
        let sessions = [
            session("master", role: "master"),
            session("worker-a", title: "Build app", role: "worker", parent: "master", agent: "codex"),
            session("worker-b", title: "  ", role: "worker", parent: "master"),
        ]
        let value = row(1, watchers: ["master", "worker-a", "worker-b", "stranger"])
        expect(PullRequestDisplayRow.make(from: [value], selectedSessionID: "master", sessions: sessions)[0].watcherTags == [
            PullRequestWatcherTag(title: "Build app", agent: "codex"), PullRequestWatcherTag(title: "worker-b", agent: ""),
        ], "master tags should show only child workers, with their agents")
        expect(PullRequestDisplayRow.make(from: [value], selectedSessionID: "worker-a", sessions: sessions)[0].watcherTags.isEmpty, "worker view should have no tags")
        let master = PullRequestDisplayRow.make(from: [value], selectedSessionID: "master", sessions: sessions)[0]
        expect(master.extraWatcherCount == 1, "two watching workers show the first and count one more")
        let solo = PullRequestDisplayRow.make(from: [row(1, watchers: ["worker-a"])], selectedSessionID: "master", sessions: sessions)[0]
        expect(solo.extraWatcherCount == 0, "one watching worker has no overflow")
        expect(PullRequestDisplayRow.make(from: [value], selectedSessionID: "worker-a", sessions: sessions)[0].extraWatcherCount == 0, "a worker's view has no overflow")
    }

    private static func rowsSortByStateThenDateThenKey() {
        let rows = [
            row(6),
            row(7, status: status(state: "future")),
            row(5, status: status(state: "merged", updated: "2026-06-20T00:00:00Z")),
            row(4, status: status(state: "closed", updated: "2026-06-20T00:00:00Z")),
            row(3, status: status(state: "open", updated: "2026-06-19T00:00:00Z")),
            row(2, status: status(state: "open", updated: "2026-06-20T00:00:00.123Z", draft: true)),
            row(1, status: status(state: "open", updated: "2026-06-20T00:00:00.123Z")),
        ]
        let sorted = PullRequestDisplayRow.make(from: rows, selectedSessionID: nil, sessions: [])
        expect(sorted.map(\.pullRequest.number) == [1, 2, 3, 4, 5, 7, 6], "rows should sort by state, time, then key, with no status last")
    }

    private static func looksStaySeparate() {
        let reviews: [(String, ReviewLook)] = [
            ("approved", .approved), ("changes_requested", .changesRequested),
            ("review_required", .reviewRequired), ("none", .none), ("future", .none),
        ]
        for (raw, look) in reviews {
            expect(display(row(1, status: status(review: raw))).reviewLook == look, "review look for \(raw)")
        }
        let cis: [(String, CILook)] = [
            ("success", .success), ("failure", .failure), ("pending", .pending),
            ("none", .none), ("future", .none),
        ]
        for (raw, look) in cis {
            expect(display(row(1, status: status(ci: raw))).ciLook == look, "CI look for \(raw)")
        }
        expect(display(row(1)).reviewLook == .none && display(row(1)).ciLook == .none, "absent status has neutral looks")
        expect(display(row(1, status: status())).rowLook == .normal, "fresh row look")
        expect(display(row(1, status: status(stale: true))).rowLook == .stale, "stale row look")
        expect(display(row(1, status: status(reason: "forbidden", stale: true))).rowLook == .inaccessible, "inaccessible takes precedence")
    }

    private static func labelsFormatEveryField() {
        let value = display(row(324, status: status(title: " Ready ", additions: 1065, deletions: 100)))
        expect(value.numberLabel == "#324", "number label")
        expect(value.repoLabel == "Owner/Repo", "GitHub repo label")
        expect(value.title == "Ready", "title label")
        expect(value.additionsLabel == "+1065" && value.deletionsLabel == "-100", "plain-digit additions and deletions labels, as the design sets them")
        expect(value.inaccessibleLabel == nil, "accessible row has no error label")

        let enterprise = display(row(42, host: "github.example.com"))
        expect(enterprise.repoLabel == "github.example.com/Owner/Repo", "enterprise host label")
        expect(enterprise.title == enterprise.pullRequest.key, "missing title falls back to ref")
        expect(enterprise.additionsLabel == nil && enterprise.deletionsLabel == nil, "missing status has no diff counter")
        for (reason, label) in [("not_found", "Not found"), ("forbidden", "No access"), ("saml", "SSO required"), ("future", "Unavailable")] {
            let unavailable = display(row(1, status: status(reason: reason)))
            expect(unavailable.inaccessibleLabel == label, "inaccessible label for \(reason)")
            expect(unavailable.additionsLabel == nil && unavailable.deletionsLabel == nil, "inaccessible row hides counters")
        }
    }

    private static func gitStateSeparatesDraftFromOpen() {
        let states: [(String, Bool, PullRequestGitState)] = [
            ("open", false, .open), ("open", true, .draft), ("merged", false, .merged),
            ("closed", false, .closed), ("future", false, .unknown),
        ]
        for (state, draft, expected) in states {
            expect(display(row(1, status: status(state: state, draft: draft))).gitState == expected, "git state for \(state) draft=\(draft)")
        }
        expect(display(row(1)).gitState == .unknown, "no status has an unknown git state")
        expect(display(row(1, status: status(reason: "forbidden"))).gitState == .unknown, "an inaccessible row has an unknown git state")
    }

    private static func urlFallsBackToTheRefAndStaysWeb() {
        let loaded = display(row(7, status: status(url: "https://github.com/Owner/Repo/pull/7")))
        expect(loaded.url?.absoluteString == "https://github.com/Owner/Repo/pull/7", "the loaded status link")
        expect(display(row(7)).url?.absoluteString == "https://github.com/Owner/Repo/pull/7", "no status links by ref")
        expect(display(row(7, host: "github.example.com")).url?.absoluteString == "https://github.example.com/Owner/Repo/pull/7", "enterprise ref link")
        for unsafe in ["file:///etc/passwd", "javascript:alert(1)", "not a url", ""] {
            expect(display(row(7, status: status(url: unsafe))).url?.absoluteString == "https://github.com/Owner/Repo/pull/7", "\(unsafe) is no web link, so the ref link stands in")
        }
    }

    private static func looksDimStaleRowsAndWarnInaccessibleOnes() {
        let fresh = display(row(1, status: status()))
        let stale = display(row(1, status: status(stale: true)))
        let inaccessible = display(row(1, status: status(reason: "saml")))
        expect(fresh.look(isCursor: false, areaFocused: true) == .rest, "a fresh row rests")
        expect(fresh.look(isCursor: true, areaFocused: true) == .highlighted, "a fresh cursor row highlights while the panel has the keys")
        expect(fresh.look(isCursor: true, areaFocused: false) == .rest, "the cursor hides when the panel doesn't have the keys: a pure cursor has no unfocused look")
        expect(fresh.look(isCursor: true, areaFocused: true) == RowLook.cursor(highlighted: true, areaFocused: true), "the look is the shared pure-cursor one")
        expect(stale.look(isCursor: false, areaFocused: true) == RowLook.rest.dimmed, "a stale row dims")
        expect(stale.look(isCursor: true, areaFocused: true) == RowLook.highlighted.dimmed, "a stale cursor row dims on its fill")
        expect(stale.look(isCursor: true, areaFocused: false) == RowLook.rest.dimmed, "a stale row's hidden cursor leaves it dimmed at rest")
        expect(inaccessible.look(isCursor: false, areaFocused: true) == RowLook.rest.dimmed.warned, "an inaccessible row dims and warns")
    }

    private static func session(_ id: String, title: String = "", role: String, parent: String = "", agent: String = "") -> TrackerSession {
        TrackerSession(id: id, title: title, repoName: "repo", agent: agent, role: role, parentID: parent)
    }

    private static func display(_ row: PullRequestRow) -> PullRequestDisplayRow {
        PullRequestDisplayRow.make(from: [row], selectedSessionID: nil, sessions: [])[0]
    }

    static func row(_ number: Int, host: String = "github.com", status: [String: Any]? = nil, watchers: [String] = []) -> PullRequestRow {
        var object: [String: Any] = [
            "key": "\(host)/owner/repo#\(number)", "host": host, "owner": "Owner", "repo": "Repo",
            "number": number,
            "watchers": watchers.map { ["session_id": $0, "added_at": "2026-06-19T00:00:00Z"] },
        ]
        if let status { object["status"] = status }
        let data = try! JSONSerialization.data(withJSONObject: object)
        return try! JSONDecoder().decode(PullRequestRow.self, from: data)
    }

    static func status(
        state: String? = "open", review: String? = "none", ci: String? = "none",
        reason: String? = nil, updated: String? = "2026-06-19T00:00:00Z", draft: Bool = false,
        title: String? = "Title", additions: Int = 0, deletions: Int = 0,
        stale: Bool = false, url: String? = nil
    ) -> [String: Any] {
        var result: [String: Any] = [
            "draft": draft, "additions": additions, "deletions": deletions,
            "changed_at": "2026-06-19T00:00:00Z", "stale": stale,
        ]
        if let state { result["state"] = state }
        if let review { result["review"] = review }
        if let ci { result["ci"] = ci }
        if let reason { result["inaccessible_reason"] = reason }
        if let updated { result["updated_at"] = updated }
        if let title { result["title"] = title }
        if let url { result["url"] = url }
        return result
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("PullRequestModelsTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
