import Foundation
import QuestmasterCore

struct WorkerChatTests {
    private static let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tokyo
        return calendar
    }

    static func run() {
        namesAreCappedAtSixteenCharacters()
        statusLinesMuteTheVerbAndColourTheTag()
        idleAndUnknownEntriesAreNotShown()
        messageKeepsParagraphsAndItemTagsCarryTheirRarity()
        actionRunCollapsesWithCountsAndNoCommas()
        actionRunSplitsAtCalendarMinute()
        lateNarrationSortsBeforeEarlierActionArrival()
        lateOtherWorkerEntryDoesNotSplitCastRun()
        actionRunClosesWhenAnotherWorkerAddsALine()
        actionRunClosesOnTheSameWorkersNextNonAction()
        lineTimesFollowTheClockMinute()
        cursorsRoundTripUnchanged()
        hasMoreRepullsImmediately()
        toolOnlyTrackerChangesDoNotPull()
        lastChatTimestampChangeTriggersPull()
        changeDuringAPullIsPickedUpByTheNextOne()
        failedPullRetriesOnNextSync()
        attachChangeResetsTheFeed()
        hiddenAttachmentChangesResetWhenReopened()
        nonMasterRolesDoNotPull()
        unreadableWorkerShowsANoticeAndRetries()
        manyUnreadableWorkersShareOneBoundedNotice()
        removedWorkerHidesItsChatLines()
        removedWorkerDuringPullKeepsCurrentEntries()
        membershipChangesWhilePullingDoNotQueueRequests()
        departedReadErrorsStayHiddenUntilReadded()
        removeAndReAddDuringPullKeepsHistory()
        standaloneIsUnattached()
        historyIsBounded()
        historyGrowsToTheCapThenTrimsInOneUpdate()
        lastUpdateAppendedOnlyForLinesAddedAtTheEnd()
        trimDoesNotResurfaceDroppedLines()
        droppedCastRunDoesNotComeBackOnRebuild()
        foldedActionsStayBounded()
        capEvictingAShownLineCountsAsTrim()
        trimKeepsTheNewestLines()
        firstLineIDStaysTheSameAcrossRebuilds()
        historyKeepsNewestLinesAtLineCap()
        print("WorkerChatTests: all tests passed")
    }

    // MARK: - Lines

    private static func namesAreCappedAtSixteenCharacters() {
        let store = makeStore()
        feed(store, [
            entry(0, "w1", "say", "hi", title: "exactly-16-chars"),
            entry(1, "w2", "say", "hi", title: "short"),
            entry(2, "w3", "say", "hi", title: "this title is much longer than sixteen"),
        ], tracker: false)
        expect(segments(store, 0).first?.text == "exactly-16-chars:", "a 16-character name should stay whole, got \(segments(store, 0))")
        expect(segments(store, 1).first?.text == "short:", "a short name should stay as is")
        expect(segments(store, 2).first?.text == "this title is mu…:", "a longer name should cut to 16 characters plus an ellipsis, got \(segments(store, 2))")
    }

    private static func statusLinesMuteTheVerbAndColourTheTag() {
        let store = makeStore()
        feed(store, [entry(0, "w1", "status", "working"), entry(1, "w1", "status", "done"), entry(2, "w1", "status", "blocked")])
        expect(
            segments(store, 0) == [
                WorkerChatSegment("Worker One:", .name),
                WorkerChatSegment(" Received status ", .muted),
                WorkerChatSegment("[Working]", .working),
            ],
            "status line mismatch: \(segments(store, 0))"
        )
        expect(segments(store, 1).last == WorkerChatSegment("[Done]", .done), "done tag mismatch")
        expect(segments(store, 2).last == WorkerChatSegment("[Blocked]", .blocked), "blocked tag mismatch")
    }

    private static func idleAndUnknownEntriesAreNotShown() {
        let store = makeStore()
        feed(store, [
            entry(0, "w1", "status", "idle"),
            entry(1, "w1", "status", "stopped"),
            entry(2, "w1", "mystery", "text"),
            entry(3, "w1", "say", "   "),
        ])
        expect(store.lines.isEmpty, "idle, unknown and blank entries should not produce lines, got \(store.lines)")
    }

    private static func messageKeepsParagraphsAndItemTagsCarryTheirRarity() {
        let store = makeStore()
        feed(store, [
            entry(0, "w1", "message", "First paragraph.\n\nSecond paragraph."),
            entry(1, "w1", "report", "Tests pass."),
            entry(2, "w1", "instructions", "Write the migration first."),
        ])
        expect(
            segments(store, 0) == [WorkerChatSegment("Worker One:", .name), WorkerChatSegment(" First paragraph.\n\nSecond paragraph.", .normal)],
            "message should stay plain text and keep its paragraphs, got \(segments(store, 0))"
        )
        expect(
            segments(store, 1) == [
                WorkerChatSegment("Worker One:", .name),
                WorkerChatSegment(" Used item ", .muted),
                WorkerChatSegment("[Debriefing Stone]", .rarity(.rare)),
            ],
            "report line mismatch: \(segments(store, 1))"
        )
        expect(
            segments(store, 2) == [
                WorkerChatSegment("Worker One:", .name),
                WorkerChatSegment(" Received item ", .muted),
                WorkerChatSegment("[Scroll of Orders]", .rarity(.epic)),
            ],
            "instructions line mismatch: \(segments(store, 2))"
        )
        let drawn = store.lines.flatMap(\.segments).map(\.text).joined()
        expect(!drawn.contains("Tests pass") && !drawn.contains("Write the migration"), "report and instruction text should not be drawn, got \(drawn)")
    }

    private static func actionRunCollapsesWithCountsAndNoCommas() {
        let store = makeStore()
        feed(store, [
            entry(0, "w1", "action", "Bash"),
            entry(1, "w1", "action", "Edit"),
            entry(2, "w1", "action", "Bash"),
            entry(3, "w1", "action", "Edit"),
            entry(4, "w1", "action", "Edit"),
            entry(5, "w1", "action", "Edit"),
            entry(6, "w1", "action", "Bash"),
        ])
        expect(store.lines.count == 1, "one run should be one line, got \(store.lines.count)")
        expect(
            segments(store, 0) == [
                WorkerChatSegment("Worker One:", .name),
                WorkerChatSegment(" Cast ", .muted),
                WorkerChatSegment("[Bash](x3) [Edit](x4)", .rarity(.common)),
            ],
            "collapsed run mismatch: \(segments(store, 0))"
        )

        let single = makeStore()
        feed(single, [entry(0, "w1", "action", "Bash")])
        expect(segments(single, 0).last?.text == "[Bash]", "a single call should show no count, got \(segments(single, 0))")
    }

    private static func actionRunSplitsAtCalendarMinute() {
        let store = makeStore()
        feed(store, [
            entry(5, "w1", "action", "Bash"),
            entry(20, "w1", "action", "Edit"),
            entry(60, "w1", "action", "Bash"),
        ])

        let entries = store.lines
        expect(entries.map(\.time) == ["09:00", "09:01"], "a run should be stamped with its first action's minute, got \(entries.map(\.time))")
        expect(entries.count == 2, "same-minute actions should fold and the next minute should split, got \(entries.count)")
        expect(entries[0].segments.dropFirst().map(\.text) == [" Cast ", "[Bash] [Edit]"], "same-minute actions should fold, got \(entries[0].segments)")
        expect(entries[1].segments.dropFirst().map(\.text) == [" Cast ", "[Bash]"], "the next-minute action should start a fresh run, got \(entries[1].segments)")
    }

    private static func lateNarrationSortsBeforeEarlierActionArrival() {
        let store = makeStore()
        let first = open(store)
        let followUp = store.receive(
            WorkerFeedPayload(entries: [
                entry(1, "w1", "action", "Read"),
                entry(3, "w1", "action", "Edit"),
            ], hasMore: ["w1": true]),
            for: first
        )
        expect(followUp != nil, "has_more should request the next page")
        expect(store.lines.count == 1, "adjacent actions should initially collapse into one Cast run")
        _ = store.receive(
            WorkerFeedPayload(entries: [entry(2, "w1", "say", "Reading the README.")]),
            for: followUp!
        )

        let entries = store.lines
        expect(entries.count == 3, "expected action, say and action rows, got \(entries.count)")
        expect(entries[0].segments.dropFirst().map(\.text) == [" Cast ", "[Read]"], "first action should precede the late say")
        expect(entries[1].segments.last?.text == " Reading the README.", "late say should sort between the already displayed actions")
        expect(entries[2].segments.dropFirst().map(\.text) == [" Cast ", "[Edit]"], "late say should split the Cast run")
    }

    private static func lateOtherWorkerEntryDoesNotSplitCastRun() {
        let store = makeStore()
        let first = open(store)
        guard let followUp = store.receive(
            WorkerFeedPayload(entries: [
                entry(1, "w1", "action", "Read"),
                entry(3, "w1", "action", "Edit"),
            ], hasMore: ["w1": true]),
            for: first
        ) else {
            fail("has_more should request the next page")
        }
        expect(store.lines.count == 1, "the first pull should combine adjacent actions")
        let originalID = store.lines.first?.id

        _ = store.receive(WorkerFeedPayload(entries: [entry(2, "w2", "action", "Read")]), for: followUp)

        let entries = store.lines
        expect(entries.count == 2, "a late other-worker entry should follow the existing Cast line, got \(entries.count)")
        expect(entries.first?.id == originalID, "the Cast line should keep its id after a late entry")
        expect(entries.first?.segments.dropFirst().map(\.text) == [" Cast ", "[Read] [Edit]"], "the Cast line should remain folded, got \(entries.first?.segments ?? [])")
        expect(entries.last?.segments.first?.text == "Worker Two:", "the late entry should follow the Cast line")
    }

    private static func actionRunClosesWhenAnotherWorkerAddsALine() {
        let store = makeStore()
        feed(store, [
            entry(0, "w1", "action", "Bash"),
            entry(1, "w2", "action", "Read"),
            entry(2, "w1", "action", "Edit"),
        ])
        let lines = store.lines
        expect(lines.count == 3, "interleaved workers should produce three Cast lines, got \(lines.count)")
        expect(lines.map { $0.segments.first?.text } == ["Worker One:", "Worker Two:", "Worker One:"], "Cast lines should keep arrival order, got \(lines)")
        expect(lines.map { $0.segments.last?.text } == ["[Bash]", "[Read]", "[Edit]"], "each interleaved action should keep its own Cast line, got \(lines)")
    }

    private static func actionRunClosesOnTheSameWorkersNextNonAction() {
        let store = makeStore()
        feed(store, [
            entry(0, "w1", "action", "Bash"),
            entry(1, "w1", "say", "done with that"),
            entry(2, "w1", "action", "Bash"),
            entry(3, "w1", "action", "Bash"),
        ])
        let lines = store.lines
        expect(lines.count == 3, "a say should close the run and the next action open a new one, got \(lines.count)")
        expect(lines[0].segments.last?.text == "[Bash]", "the closed run keeps its own count")
        expect(lines[2].segments.last?.text == "[Bash](x2)", "the new run counts only its own calls, got \(lines[2].segments)")
    }

    // MARK: - Times

    private static func lineTimesFollowTheClockMinute() {
        let store = makeStore()
        feed(store, [
            entry(0, "w1", "say", "a"),
            entry(30, "w1", "say", "b"),
            entry(60, "w1", "say", "c"),
            entry(119, "w1", "say", "d"),
            entry(120 + 20 * 60, "w1", "say", "e"),
        ])
        expect(store.lines.map(\.time) == ["09:00", "09:00", "09:01", "09:01", "09:22"], "line time mismatch: \(store.lines.map(\.time))")

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let utcStore = WorkerChatStore(calendar: utc)
        feed(utcStore, [entry(0, "w1", "say", "a"), entry(59, "w1", "say", "b"), entry(60, "w1", "say", "c")])
        expect(utcStore.lines.map(\.time) == ["00:00", "00:00", "00:01"], "UTC line times were \(utcStore.lines.map(\.time))")
    }

    // MARK: - Pulling

    private static func cursorsRoundTripUnchanged() {
        let store = makeStore()
        let first = open(store)
        expect(first.cursors.isEmpty, "the first pull starts without cursors")
        let cursor = WorkerFeedCursor(offset: 128, fileID: "1:42")
        _ = store.receive(WorkerFeedPayload(entries: [], cursors: ["w1": cursor]), for: first)
        var changed = group()
        changed[1].lastChatAt = base(1)
        let next = store.sync(selectedSessionID: "m", sessions: changed, isVisible: true)
        expect(next?.cursors == ["w1": cursor], "the backend's cursors should come back unchanged, got \(String(describing: next?.cursors))")

        let object = next?.jsonObject(id: "req") ?? [:]
        let data = object["data"] as? [String: Any]
        let cursors = data?["cursors"] as? [String: [String: Any]]
        expect(object["method"] as? String == "worker_feed", "method should be worker_feed")
        expect(data?["master_id"] as? String == "m", "master_id should be the attached master")
        expect(cursors?["w1"]?["offset"] as? Int64 == 128, "cursor offset should be sent as is")
        expect(cursors?["w1"]?["file_id"] as? String == "1:42", "cursor file_id should be sent as is")
    }

    private static func hasMoreRepullsImmediately() {
        let store = makeStore()
        let first = open(store)
        let second = store.receive(
            WorkerFeedPayload(cursors: ["w1": WorkerFeedCursor(offset: 10, fileID: "a")], hasMore: ["w1": true, "w2": false]),
            for: first
        )
        expect(second != nil, "has_more should pull again straight away")
        expect(second?.cursors["w1"]?.offset == 10, "the re-pull should carry the new cursor")
        let third = store.receive(WorkerFeedPayload(cursors: ["w1": WorkerFeedCursor(offset: 20, fileID: "a")], hasMore: ["w1": false]), for: second!)
        expect(third == nil, "no has_more means no further pull")
    }

    private static func toolOnlyTrackerChangesDoNotPull() {
        let store = makeStore()
        expect(store.sync(selectedSessionID: "m", sessions: group(), isVisible: false) == nil, "a closed dock should not pull")
        let first = store.sync(selectedSessionID: "m", sessions: group(), isVisible: true)
        expect(first != nil, "opening the dock should pull")
        _ = store.receive(WorkerFeedPayload(), for: first!)
        expect(store.sync(selectedSessionID: "m", sessions: group(), isVisible: true) == nil, "an unchanged tracker should not pull")
        var toolChange = group(snippet: "Bash: ls")
        toolChange[1].state = "working"
        toolChange[1].lifecycle = "active"
        toolChange[1].lastKind = "PreToolUse"
        expect(store.sync(selectedSessionID: "m", sessions: toolChange, isVisible: true) == nil, "tool-only tracker changes should not pull chat")
        var chatChange = toolChange
        chatChange[1].lastChatAt = base(1)
        expect(store.sync(selectedSessionID: "m", sessions: chatChange, isVisible: true) != nil, "new chat should still pull")
    }

    private static func lastChatTimestampChangeTriggersPull() {
        let store = makeStore()
        let first = open(store)
        _ = store.receive(WorkerFeedPayload(), for: first)
        var updated = group()
        updated[1].lastChatAt = base(1)
        expect(store.sync(selectedSessionID: "m", sessions: updated, isVisible: true) != nil, "new worker chat should trigger a pull")
    }

    private static func changeDuringAPullIsPickedUpByTheNextOne() {
        let store = makeStore()
        let first = open(store)
        var changed = group(snippet: "changed")
        changed[1].lastChatAt = base(1)
        expect(store.sync(selectedSessionID: "m", sessions: changed, isVisible: true) == nil, "only one pull should be in flight")
        let followUp = store.receive(WorkerFeedPayload(), for: first)
        expect(followUp != nil, "the change seen mid-pull should trigger a follow-up")
    }

    private static func failedPullRetriesOnNextSync() {
        let store = makeStore()
        let first = open(store)
        store.fail(first)
        let retry = store.sync(selectedSessionID: "m", sessions: group(), isVisible: true)
        expect(retry != nil, "a failed pull should retry on the next sync")
    }

    // MARK: - Attach

    private static func attachChangeResetsTheFeed() {
        let store = makeStore()
        let first = open(store)
        _ = store.receive(
            WorkerFeedPayload(
                entries: [entry(0, "w1", "say", "hello")],
                cursors: ["w1": WorkerFeedCursor(offset: 5, fileID: "a")]
            ),
            for: first
        )
        expect(store.lines.count == 1, "one say line expected, got \(store.lines.count)")

        let otherMaster = [
            TrackerSession(id: "m2", title: "Other", repoName: "Repo", role: "master"),
            TrackerSession(id: "x1", title: "X", repoName: "Repo", agent: "codex", role: "worker", parentID: "m2"),
        ]
        let request = store.sync(selectedSessionID: "m2", sessions: otherMaster, isVisible: true)
        expect(store.lines.isEmpty, "switching master should clear the feed")
        expect(request?.masterID == "m2", "the new pull should target the new master")
        expect(request?.cursors.isEmpty == true, "the new pull should start without the old cursors")

        let stale = store.receive(
            WorkerFeedPayload(entries: [entry(1, "w1", "say", "late")], cursors: ["w1": WorkerFeedCursor(offset: 9, fileID: "a")]),
            for: first
        )
        expect(stale == nil && store.lines.isEmpty, "a response for the old master should be dropped")
    }

    private static func hiddenAttachmentChangesResetWhenReopened() {
        let store = makeStore()
        let first = open(store)
        _ = store.receive(WorkerFeedPayload(entries: [entry(0, "w1", "say", "hello")]), for: first)
        expect(store.lines.count == 1, "the current feed should be visible before hiding")
        expect(store.sync(selectedSessionID: "m2", sessions: [], isVisible: false) == nil, "a hidden dock should not pull")
        expect(store.lines.count == 1, "a hidden selection change should wait to reset the visible feed")

        let otherMaster = [
            TrackerSession(id: "m2", title: "Other", repoName: "Repo", role: "master"),
            TrackerSession(id: "x1", title: "X", repoName: "Repo", agent: "codex", role: "worker", parentID: "m2"),
        ]
        let request = store.sync(selectedSessionID: "m2", sessions: otherMaster, isVisible: true)
        expect(request?.masterID == "m2" && store.lines.isEmpty, "opening on another master should reset and pull its feed")
    }

    private static func nonMasterRolesDoNotPull() {
        for role in ["worker", "standalone", "tmux", "orphan", "future-role"] {
            let store = makeStore()
            let sessions = [
                TrackerSession(id: "m", title: "Master", repoName: "Repo", role: "master"),
                TrackerSession(id: "selected", title: "Selected", repoName: "Repo", role: role, parentID: "m"),
                TrackerSession(id: "w1", title: "Sibling", repoName: "Repo", role: "worker", parentID: "m"),
            ]
            let request = store.sync(selectedSessionID: "selected", sessions: sessions, isVisible: true)
            expect(request == nil, "a selected \(role) session should not pull worker chat")
            expect(!store.isAttached && store.lines.isEmpty && store.readNotice == nil, "a selected \(role) session should have no feed state")
        }
    }

    private static func unreadableWorkerShowsANoticeAndRetries() {
        let store = makeStore()
        let request = open(store)
        let followUp = store.receive(
            WorkerFeedPayload(
                entries: [entry(0, "w1", "say", "hi")],
                cursors: ["w1": WorkerFeedCursor(offset: 3, fileID: "a")],
                errors: ["w2": "permission denied"]
            ),
            for: request
        )
        expect(followUp == nil, "an error alone should not re-pull straight away")
        expect(store.lines.count == 1, "the readable worker's entries should still show")
        expect(store.readNotice == "Couldn't read Worker Two's activity", "notice mismatch: \(String(describing: store.readNotice))")

        let retry = store.sync(selectedSessionID: "m", sessions: group(), isVisible: true)
        expect(retry != nil, "the next sync should re-pull while a worker is in error, even with no change")
        _ = store.receive(WorkerFeedPayload(), for: retry!)
        expect(store.readNotice == nil, "a clean pull should clear the notice")
        expect(store.sync(selectedSessionID: "m", sessions: group(), isVisible: true) == nil, "no error and no change should not pull")
    }

    private static func manyUnreadableWorkersShareOneBoundedNotice() {
        func sameTitled(_ ids: [String]) -> [TrackerSession] {
            [TrackerSession(id: "m", title: "Master", repoName: "Repo", role: "master")]
                + ids.map { TrackerSession(id: $0, title: "Same", repoName: "Repo", agent: "codex", role: "worker", parentID: "m") }
        }
        let store = makeStore()
        let request = store.sync(selectedSessionID: "m", sessions: sameTitled(["a", "b"]), isVisible: true)!
        _ = store.receive(WorkerFeedPayload(errors: ["a": "denied", "b": "denied"]), for: request)
        expect(store.readNotice == "Couldn't read activity for Same, Same", "two same-titled workers should both be named, got \(String(describing: store.readNotice))")

        let more = store.sync(selectedSessionID: "m", sessions: sameTitled(["a", "b", "c", "d", "e"]), isVisible: true)!
        _ = store.receive(WorkerFeedPayload(errors: ["a": "x", "b": "x", "c": "x", "d": "x", "e": "x"]), for: more)
        expect(store.readNotice == "Couldn't read activity for Same, Same (+3)", "extra workers should be counted, got \(String(describing: store.readNotice))")
    }

    private static func removedWorkerHidesItsChatLines() {
        let store = makeStore()
        let first = open(store)
        let w1Cursor = WorkerFeedCursor(offset: 3, fileID: "w1-file")
        let w2Cursor = WorkerFeedCursor(offset: 5, fileID: "w2-file")
        _ = store.receive(
            WorkerFeedPayload(
                entries: [entry(0, "w1", "say", "leaving"), entry(1, "w2", "say", "staying")],
                cursors: ["w1": w1Cursor, "w2": w2Cursor],
                errors: ["w1": "permission denied"]
            ),
            for: first
        )
        let w2LinesBefore = store.lines.filter { $0.agent == "claude" }.map { $0.segments }
        expect(store.readNotice == "Couldn't read Worker One's activity", "the unreadable worker should have a notice before removal")

        let remainingGroup = group().filter { $0.id != "w1" }
        let next = store.sync(selectedSessionID: "m", sessions: remainingGroup, isVisible: true)
        let w2LinesAfter = store.lines.filter { $0.agent == "claude" }.map { $0.segments }
        expect(!store.lines.contains { $0.segments.first?.text == "Worker One:" }, "removed worker lines should disappear")
        expect(w2LinesAfter == w2LinesBefore && w2LinesAfter.count == 1, "remaining worker lines should be unchanged")
        expect(next?.cursors == ["w1": w1Cursor, "w2": w2Cursor], "the hidden worker cursor should be retained, got \(String(describing: next?.cursors))")
        expect(store.readNotice == nil, "removed worker read errors should disappear")
    }

    private static func removedWorkerDuringPullKeepsCurrentEntries() {
        let store = makeStore()
        let first = open(store)
        let remainingGroup = group().filter { $0.id != "w1" }
        let current = store.sync(selectedSessionID: "m", sessions: remainingGroup, isVisible: true)
        expect(current == nil, "membership changes should not issue another request while a pull is in flight")

        let w2Cursor = WorkerFeedCursor(offset: 10, fileID: "w2-file")
        let followUp = store.receive(
            WorkerFeedPayload(
                entries: [entry(2, "w1", "say", "resurrected"), entry(3, "w2", "say", "late")],
                cursors: ["w1": WorkerFeedCursor(offset: 9, fileID: "w1-file"), "w2": w2Cursor],
                hasMore: ["w1": true],
                errors: ["w1": "permission denied"]
            ),
            for: first
        )

        let w2Lines = store.lines.filter { $0.agent == "claude" }.map { $0.segments }
        expect(!store.lines.contains { $0.segments.first?.text == "Worker One:" }, "removed worker entries should be dropped")
        expect(w2Lines.count == 1 && w2Lines[0].last?.text == " late", "the remaining worker's new entry should be shown")
        expect(store.readNotice == nil, "removed worker read errors should be dropped")
        expect(followUp?.cursors == ["w1": WorkerFeedCursor(offset: 9, fileID: "w1-file"), "w2": w2Cursor], "the response cursors should be retained while the worker is hidden")

        _ = store.receive(WorkerFeedPayload(), for: followUp!)
        expect(store.sync(selectedSessionID: "m", sessions: remainingGroup, isVisible: true) == nil, "the completed feed should not request another pull")
    }

    private static func membershipChangesWhilePullingDoNotQueueRequests() {
        let store = makeStore()
        let first = open(store)
        let remainingGroup = group().filter { $0.id != "w1" }
        expect(store.sync(selectedSessionID: "m", sessions: remainingGroup, isVisible: true) == nil, "removing a worker should keep the current pull in flight")
        expect(store.sync(selectedSessionID: "m", sessions: group(), isVisible: true) == nil, "re-adding a worker should not queue another pull")
        expect(store.sync(selectedSessionID: "m", sessions: remainingGroup, isVisible: true) == nil, "repeated membership changes should not queue pulls")

        let w2Cursor = WorkerFeedCursor(offset: 10, fileID: "w2-file")
        let followUp = store.receive(
            WorkerFeedPayload(
                entries: [entry(0, "w1", "say", "removed"), entry(1, "w2", "say", "kept")],
                cursors: ["w1": WorkerFeedCursor(offset: 9, fileID: "w1-file"), "w2": w2Cursor],
                errors: ["w1": "permission denied"]
            ),
            for: first
        )
        expect(followUp?.cursors == ["w1": WorkerFeedCursor(offset: 9, fileID: "w1-file"), "w2": w2Cursor], "the completed pull should issue one follow-up with cached cursors")
        expect(!store.lines.contains { $0.segments.first?.text == "Worker One:" }, "the final group should not show the removed worker")
        expect(store.lines.contains { $0.segments.last?.text == " kept" }, "the final group should keep the remaining worker")
        _ = store.receive(WorkerFeedPayload(errors: ["w1": "permission denied"]), for: followUp!)
        expect(store.readNotice == nil, "the removed worker error should stay hidden")
        expect(store.sync(selectedSessionID: "m", sessions: remainingGroup, isVisible: true) == nil, "a hidden worker error should not trigger retries")
    }

    private static func departedReadErrorsStayHiddenUntilReadded() {
        let store = makeStore()
        let first = open(store)
        _ = store.receive(WorkerFeedPayload(errors: ["w1": "permission denied"]), for: first)
        expect(store.readNotice == "Couldn't read Worker One's activity", "current worker errors should be shown")

        let remainingGroup = group().filter { $0.id != "w1" }
        let next = store.sync(selectedSessionID: "m", sessions: remainingGroup, isVisible: true)
        expect(next != nil && store.readNotice == nil, "a departed worker's error should be hidden")
        expect(store.sync(selectedSessionID: "m", sessions: group(), isVisible: true) == nil, "re-adding should keep the in-flight request")
        expect(store.readNotice == "Couldn't read Worker One's activity", "the cached error should return when the worker rejoins")
    }

    private static func removeAndReAddDuringPullKeepsHistory() {
        let store = makeStore()
        let first = open(store)
        let initialEntries = (0..<100).map { _ in entry(0, "w1", "action", "Bash") }
            + (0..<400).map { _ in entry(0, "w2", "action", "Read") }
        _ = store.receive(WorkerFeedPayload(entries: initialEntries), for: first)

        let remainingGroup = group().filter { $0.id != "w2" }
        let pull = store.sync(selectedSessionID: "m", sessions: remainingGroup, isVisible: true)
        expect(pull != nil, "removing a worker should request the current group")
        let additions = (0..<100).map { _ in entry(1, "w1", "action", "Bash") }
        let pending = store.receive(WorkerFeedPayload(entries: additions, hasMore: ["w1": true]), for: pull!)
        let aLines = store.lines.filter { $0.agent == "codex" }
        expect(aLines.count == 1 && aLines[0].segments.last?.text == "[Bash](x200)", "visible worker history should keep all 200 actions")
        expect(pending != nil, "has_more should leave one pull in flight")

        var rejoinedGroup = group()
        rejoinedGroup[2].title = ""
        expect(store.sync(selectedSessionID: "m", sessions: rejoinedGroup, isVisible: true) == nil, "re-adding should keep the existing pull")
        let bLines = store.lines.filter { $0.agent == "claude" }
        expect(bLines.count == 1 && bLines[0].segments.last?.text == "[Read](x400)", "re-adding B should restore its retained hidden history")
        expect(bLines[0].segments.first?.text == "Worker Two:", "the cached feed name should survive the omission")
    }

    private static func standaloneIsUnattached() {
        let store = makeStore()
        let standalone = [TrackerSession(id: "s", title: "Solo", repoName: "Repo", role: "standalone")]
        expect(store.sync(selectedSessionID: "s", sessions: standalone, isVisible: true) == nil, "standalone has nothing to pull")
        expect(!store.isAttached && store.lines.isEmpty, "standalone should be unattached and empty")
        expect(store.sync(selectedSessionID: nil, sessions: standalone, isVisible: true) == nil, "no selection has nothing to pull")
        expect(!store.isAttached, "no selection is unattached")
    }

    // MARK: - History

    private static func historyIsBounded() {
        let store = makeStore()
        let first = open(store)
        let entries = (0..<(WorkerChatStore.maxLines + 100)).map { entry(TimeInterval($0), "w1", "say", "line \($0)") }
        _ = store.receive(WorkerFeedPayload(entries: entries), for: first)
        expect(store.lines.count == WorkerChatStore.trimTarget, "an overflowing history should trim to \(WorkerChatStore.trimTarget) lines, got \(store.lines.count)")
        expect(store.trimCount == 1, "one overflowing payload should trim once, got \(store.trimCount)")
        expect(store.lines.first.map(lastText) == " line 200", "the kept lines should start at the oldest of the newest \(WorkerChatStore.trimTarget), got \(store.lines.first.map(lastText) ?? "")")
        expect(store.lines.last.map(lastText) == " line \(WorkerChatStore.maxLines + 99)", "the newest line should be kept")
        expect(!store.lines.contains { lastText($0) == " line 0" }, "the oldest lines should be dropped")
    }

    private static func historyGrowsToTheCapThenTrimsInOneUpdate() {
        let store = makeStore()
        let first = open(store)
        let fill = (0..<WorkerChatStore.maxLines).map { entry(0, "w1", "say", "line \($0)") }
        _ = store.receive(WorkerFeedPayload(entries: fill), for: first)
        expect(store.lines.count == WorkerChatStore.maxLines, "history should grow to the cap without trimming, got \(store.lines.count)")
        expect(store.trimCount == 0, "history at the cap should not trim yet")

        _ = store.receive(WorkerFeedPayload(entries: [entry(0, "w1", "say", "over the cap")]), for: first)
        expect(store.lines.count == WorkerChatStore.trimTarget, "one line over the cap should trim straight to \(WorkerChatStore.trimTarget), got \(store.lines.count)")
        expect(store.trimCount == 1, "the trim should count once, got \(store.trimCount)")
        expect(!store.lastUpdateAppended, "a trim should not count as an append")
        expect(store.revision > 0, "every replacement of the lines should advance the revision")

        _ = store.receive(WorkerFeedPayload(entries: [entry(0, "w1", "say", "after trim")]), for: first)
        expect(store.trimCount == 1, "arrivals after a trim should grow the history again without trimming")
        expect(store.lines.count == WorkerChatStore.trimTarget + 1, "the next arrival should append, got \(store.lines.count)")
        expect(store.lastUpdateAppended, "an arrival after a trim should be an append")
    }

    /// The feed fades only arrivals that sit below the old rows, so the store reports when an update
    /// added lines at the end and nothing else: an older line that sorts in above the newest is not one.
    private static func lastUpdateAppendedOnlyForLinesAddedAtTheEnd() {
        let store = makeStore()
        let first = open(store)
        _ = store.receive(WorkerFeedPayload(entries: [entry(10, "w1", "say", "one")]), for: first)
        expect(store.lastUpdateAppended, "the first lines should count as an append")
        _ = store.receive(WorkerFeedPayload(entries: [entry(20, "w1", "say", "two")]), for: first)
        expect(store.lastUpdateAppended, "a newer line should be an append")
        _ = store.receive(WorkerFeedPayload(entries: [entry(5, "w1", "say", "older")]), for: first)
        expect(!store.lastUpdateAppended, "a line that sorts above the newest should not be an append")
    }

    /// 400 entries in one minute, then 201 in the next: 601 lines, so the trim keeps the newest 500,
    /// which starts 100 entries into the first minute.
    private static func trimKeepsTheNewestLines() {
        let store = makeStore()
        let first = open(store)
        let early = (0..<400).map { entry(0, "w1", "say", "a \($0)") }
        let late = (0..<201).map { entry(60, "w1", "say", "b \($0)") }
        _ = store.receive(WorkerFeedPayload(entries: early + late), for: first)

        expect(store.trimCount == 1, "the overflow should trim once, got \(store.trimCount)")
        expect(store.lines.count == WorkerChatStore.trimTarget, "a trim should keep exactly \(WorkerChatStore.trimTarget) lines, got \(store.lines.count)")
        expect(store.lines.first.map(lastText) == " a 101", "the kept lines should start at the oldest of the newest entries, got \(store.lines.first.map(lastText) ?? "")")
        expect(store.lines.last.map(lastText) == " b 200", "the newest line should be kept")
        expect(!store.lines.contains { lastText($0) == " a 100" }, "the entry before the cut should be dropped")
    }

    /// A line keeps its id when the trim leaves it first, so the feed's row identity doesn't churn on
    /// the next rebuild.
    private static func firstLineIDStaysTheSameAcrossRebuilds() {
        let store = makeStore()
        let entries = (0...WorkerChatStore.maxLines).map { entry(0, "w\($0)", "action", "Bash") }
        feed(store, entries, tracker: false)
        let firstID = store.lines.first?.id
        expect(firstID == "e101", "the trimmed feed should open with the oldest kept line, got \(String(describing: firstID))")

        var renamed = [TrackerSession(id: "m", title: "Master", repoName: "Repo", role: "master")]
        renamed += (0...WorkerChatStore.maxLines).map { index in
            TrackerSession(id: "w\(index)", title: index == 0 ? "Renamed" : "", repoName: "Repo", role: "worker", parentID: "m")
        }
        _ = store.sync(selectedSessionID: "m", sessions: renamed, isVisible: true)
        expect(store.lines.first?.id == firstID, "the first line id should not change on a rebuild, got \(String(describing: store.lines.first?.id)) for \(String(describing: firstID))")
    }

    private static func trimDoesNotResurfaceDroppedLines() {
        let store = makeStore()
        let entries = (0...WorkerChatStore.maxLines).map { entry(0, "w\($0)", "action", "Bash") }
        feed(store, entries, tracker: false)
        let trimmedCount = store.lines.count
        expect(store.trimCount == 1, "the overflow should trim once, got \(store.trimCount)")

        let workers = (0...WorkerChatStore.maxLines).map { index in
            TrackerSession(id: "w\(index)", title: index == 0 ? "Renamed" : "", repoName: "Repo", role: "worker", parentID: "m")
        }
        let sessions = [TrackerSession(id: "m", title: "Master", repoName: "Repo", role: "master")] + workers
        _ = store.sync(selectedSessionID: "m", sessions: sessions, isVisible: true)
        expect(store.lines.count == trimmedCount, "a rebuild with no new records should keep the trimmed history, got \(store.lines.count)")
        expect(store.trimCount == 1, "a rebuild with no new records should not trim again, got \(store.trimCount)")
    }

    /// Worker One casts at 09:00:00 and 09:00:59, and Worker Two's 600 messages arrive later, timestamped
    /// between them. The Cast run folds both actions into its first line, the trim drops that line, and the
    /// 09:00:59 action must not come back when the feed is rebuilt.
    private static func droppedCastRunDoesNotComeBackOnRebuild() {
        let store = makeStore()
        let first = open(store)
        guard let followUp = store.receive(
            WorkerFeedPayload(entries: [entry(0, "w1", "action", "Bash"), entry(59, "w1", "action", "Edit")], hasMore: ["w1": true]),
            for: first
        ) else {
            fail("has_more should request the next page")
        }
        _ = store.receive(WorkerFeedPayload(entries: (0..<600).map { entry(TimeInterval(1 + $0 % 58), "w2", "say", "b \($0)") }), for: followUp)
        expect(store.trimCount == 1, "the overflow should trim once, got \(store.trimCount)")
        expect(store.lines.count == WorkerChatStore.trimTarget, "the trim should keep \(WorkerChatStore.trimTarget) lines, got \(store.lines.count)")

        var renamed = group()
        renamed[1].title = "Renamed"
        _ = store.sync(selectedSessionID: "m", sessions: renamed, isVisible: true)
        expect(!store.lines.contains { $0.segments.first?.text == "Renamed:" }, "the dropped Cast run should not reappear after a rebuild")
        expect(!store.lines.contains { $0.segments.contains { $0.text.contains("[Edit]") } }, "the 09:00:59 action should not survive the trim")
        expect(store.lines.count == WorkerChatStore.trimTarget, "a rebuild should keep the trimmed history, got \(store.lines.count)")
        expect(store.trimCount == 1, "a rebuild with no new records should not trim again, got \(store.trimCount)")
    }

    /// One worker's actions in one minute fold into a single line, so the line trim never fires. The raw
    /// records must still stop at `maxRecords`, and the run counts only the newest of them.
    private static func foldedActionsStayBounded() {
        let store = makeStore()
        let first = open(store)
        guard let followUp = store.receive(
            WorkerFeedPayload(entries: (0..<WorkerChatStore.maxRecords).map { _ in entry(0, "w1", "action", "Bash") }, hasMore: ["w1": true]),
            for: first
        ) else {
            fail("has_more should request the next page")
        }
        _ = store.receive(WorkerFeedPayload(entries: (0..<500).map { _ in entry(0, "w1", "action", "Bash") }), for: followUp)
        expect(store.lines.count == 1, "one worker's run in one minute should stay one line, got \(store.lines.count)")
        expect(store.lines.last?.segments.last?.text == "[Bash](x\(WorkerChatStore.maxRecords))", "the run should count only the \(WorkerChatStore.maxRecords) newest records, got \(store.lines.last?.segments.last?.text ?? "")")
        expect(store.trimCount == 0, "a folded run should not trim, got \(store.trimCount)")
    }

    /// A message, then 1,199 same-minute actions (two rows, 1,200 records). The next action makes the cap drop
    /// the message, which leaves one row and no line trim. That still counts as a trim, so the follower doesn't
    /// glide the surviving row.
    private static func capEvictingAShownLineCountsAsTrim() {
        let store = makeStore()
        let first = open(store)
        guard let followUp = store.receive(
            WorkerFeedPayload(
                entries: [entry(0, "w1", "say", "old message")] + (0..<1199).map { _ in entry(0, "w1", "action", "Bash") },
                hasMore: ["w1": true]
            ),
            for: first
        ) else {
            fail("has_more should request the next page")
        }
        expect(store.lines.count == 2 && store.trimCount == 0, "a message and its Cast run should be two rows with no trim, got \(store.lines.count) rows and \(store.trimCount) trims")

        _ = store.receive(WorkerFeedPayload(entries: [entry(0, "w1", "action", "Bash")]), for: followUp)
        expect(store.lines.count == 1, "the cap should evict the message, leaving one row, got \(store.lines.count)")
        expect(store.lines.first?.segments.last?.text == "[Bash](x\(WorkerChatStore.maxRecords))", "the surviving row should be the Cast run, got \(String(describing: store.lines.first?.segments))")
        expect(store.trimCount == 1, "evicting a line that was on screen should count as a trim, got \(store.trimCount)")
    }

    /// One action per minute for 601 minutes: the trim keeps the newest 500, from 10:41 to 19:00.
    private static func historyKeepsNewestLinesAtLineCap() {
        let store = makeStore()
        let first = open(store)
        let entries = (0...WorkerChatStore.maxLines).map { entry(TimeInterval($0 * 60), "w1", "action", "Bash") }
        _ = store.receive(WorkerFeedPayload(entries: entries), for: first)

        expect(store.lines.count == WorkerChatStore.trimTarget, "rendered history should trim to \(WorkerChatStore.trimTarget) lines, got \(store.lines.count)")
        expect(store.lines.first?.time == "10:41", "the oldest kept line should be 10:41, got \(String(describing: store.lines.first?.time))")
        expect(store.lines.last?.time == "19:00", "the newest line should keep its time, got \(String(describing: store.lines.last?.time))")
        expect(store.lines.last?.segments.last?.text == "[Bash]", "the newest action should remain visible, got \(String(describing: store.lines.last?.segments))")
    }

    // MARK: - Helpers

    private static func makeStore() -> WorkerChatStore {
        WorkerChatStore(calendar: calendar)
    }

    /// 2026-10-07 09:00:00 Tokyo plus `seconds`.
    private static func base(_ seconds: TimeInterval) -> Date {
        DateComponents(calendar: calendar, timeZone: tokyo, year: 2026, month: 10, day: 7, hour: 9).date!.addingTimeInterval(seconds)
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: base(seconds))
    }

    private static func entry(_ seconds: TimeInterval, _ worker: String, _ kind: String, _ text: String, title: String? = nil) -> WorkerFeedEntry {
        WorkerFeedEntry(
            timestamp: timestamp(seconds),
            workerID: worker,
            workerTitle: title ?? (worker == "w1" ? "Worker One" : "Worker Two"),
            kind: kind,
            text: text
        )
    }

    private static func group(snippet: String = "") -> [TrackerSession] {
        [
            TrackerSession(id: "m", title: "Master", repoName: "Repo", agent: "claude", role: "master"),
            TrackerSession(id: "w1", title: "Worker One", repoName: "Repo", agent: "codex", role: "worker", snippet: snippet, parentID: "m"),
            TrackerSession(id: "w2", title: "Worker Two", repoName: "Repo", agent: "claude", role: "worker", parentID: "m"),
        ]
    }

    private static func open(_ store: WorkerChatStore) -> WorkerFeedRequest {
        guard let request = store.sync(selectedSessionID: "m", sessions: group(), isVisible: true) else {
            fail("opening the dock should have produced a request")
        }
        return request
    }

    /// Opens the dock and applies one response. `tracker: false` keeps tracker titles out so the
    /// feed's own titles are what shows.
    private static func feed(_ store: WorkerChatStore, _ entries: [WorkerFeedEntry], tracker: Bool = true) {
        let sessions = tracker
            ? group()
            : [TrackerSession(id: "m", title: "Master", repoName: "Repo", role: "master")]
                + Set(entries.map(\.workerID)).map { TrackerSession(id: $0, title: "", repoName: "Repo", role: "worker", parentID: "m") }
        let request = store.sync(selectedSessionID: "m", sessions: sessions, isVisible: true)
        _ = store.receive(WorkerFeedPayload(entries: entries), for: request!)
    }

    private static func segments(_ store: WorkerChatStore, _ index: Int) -> [WorkerChatSegment] {
        let lines = store.lines
        return index < lines.count ? lines[index].segments : []
    }

    private static func lastText(_ line: WorkerChatLine) -> String {
        line.segments.last?.text ?? ""
    }

    private static func fail(_ message: String) -> Never {
        fputs("WorkerChatTests failed: \(message)\n", stderr)
        Foundation.exit(1)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fail(message)
        }
    }
}
