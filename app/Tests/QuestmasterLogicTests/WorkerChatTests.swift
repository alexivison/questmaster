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
        messageKeepsParagraphsAndReportMutesItsText()
        onlyFreeTextEntriesAreNarration()
        actionRunCollapsesWithCountsAndNoCommas()
        lateNarrationSortsBeforeEarlierActionArrival()
        actionRunStaysOpenAcrossOtherWorkersEntries()
        actionRunClosesOnTheSameWorkersNextNonAction()
        timeHeadersFollowTheClockMinuteOfTheLastHeader()
        cursorsRoundTripUnchanged()
        hasMoreRepullsImmediately()
        toolOnlyTrackerChangesDoNotPull()
        lastChatTimestampChangeTriggersPull()
        changeDuringAPullIsPickedUpByTheNextOne()
        failedPullRetriesOnNextSync()
        attachChangeResetsTheFeed()
        hiddenAttachmentChangesResetWhenReopened()
        attachChangeWithinTheGroupPullsAgainKeepingCursors()
        unreadableWorkerShowsANoticeAndRetries()
        manyUnreadableWorkersShareOneBoundedNotice()
        removedWorkerHidesItsChatLines()
        removedWorkerDuringPullKeepsCurrentEntries()
        membershipChangesWhilePullingDoNotQueueRequests()
        departedReadErrorsStayHiddenUntilReadded()
        removeAndReAddDuringPullKeepsHistory()
        standaloneIsUnattached()
        historyIsBounded()
        roleAvailability()
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

    private static func messageKeepsParagraphsAndReportMutesItsText() {
        let store = makeStore()
        feed(store, [
            entry(0, "w1", "message", "First paragraph.\n\nSecond paragraph."),
            entry(1, "w1", "report", "Tests pass."),
        ])
        expect(
            segments(store, 0) == [WorkerChatSegment("Worker One:", .name), WorkerChatSegment(" First paragraph.\n\nSecond paragraph.", .normal)],
            "message should keep its paragraphs, got \(segments(store, 0))"
        )
        expect(
            segments(store, 1) == [
                WorkerChatSegment("Worker One:", .name),
                WorkerChatSegment(" [Report] ", .normal),
                WorkerChatSegment("Tests pass.", .muted),
            ],
            "report line mismatch: \(segments(store, 1))"
        )
    }

    private static func onlyFreeTextEntriesAreNarration() {
        let store = makeStore()
        feed(store, [
            entry(0, "w1", "status", "working"),
            entry(1, "w1", "action", "Bash"),
            entry(2, "w1", "say", "Looking."),
            entry(3, "w1", "message", "Hello."),
            entry(4, "w1", "report", "Done."),
        ])
        let flags = store.lines.filter { line in
            if case .entry = line.content { return true }
            return false
        }.map(\.isNarration)
        expect(flags == [false, false, true, true, true], "only say, message and report should be narration, got \(flags)")
        expect(store.lines.first.map { !$0.isNarration } == true, "time headers are not narration")
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
        expect(entryLines(store).count == 1, "one run should be one line, got \(entryLines(store).count)")
        expect(
            segments(store, 0) == [
                WorkerChatSegment("Worker One:", .name),
                WorkerChatSegment(" Cast ", .muted),
                WorkerChatSegment("[Bash](x3) [Edit](x4)", .normal),
            ],
            "collapsed run mismatch: \(segments(store, 0))"
        )

        let single = makeStore()
        feed(single, [entry(0, "w1", "action", "Bash")])
        expect(segments(single, 0).last?.text == "[Bash]", "a single call should show no count, got \(segments(single, 0))")
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
        expect(entryLines(store).count == 1, "adjacent actions should initially collapse into one Cast run")
        _ = store.receive(
            WorkerFeedPayload(entries: [entry(2, "w1", "say", "Reading the README.")]),
            for: followUp!
        )

        let entries = entryLines(store)
        expect(entries.count == 3, "expected action, say and action rows, got \(entries.count)")
        expect(entries[0].segments.dropFirst().map(\.text) == [" Cast ", "[Read]"], "first action should precede the late say")
        expect(entries[1].segments.last?.text == " Reading the README.", "late say should sort between the already displayed actions")
        expect(entries[2].segments.dropFirst().map(\.text) == [" Cast ", "[Edit]"], "late say should split the Cast run")
    }

    private static func actionRunStaysOpenAcrossOtherWorkersEntries() {
        let store = makeStore()
        feed(store, [
            entry(0, "w1", "action", "Bash"),
            entry(1, "w2", "action", "Read"),
            entry(2, "w2", "say", "looking"),
            entry(3, "w1", "action", "Bash"),
            entry(4, "w1", "action", "Edit"),
        ])
        let lines = entryLines(store)
        expect(lines.count == 3, "expected w1's run, w2's run and w2's say, got \(lines.count)")
        expect(lines[0].segments.last?.text == "[Bash](x2) [Edit]", "w1's run should keep growing in its original place, got \(lines[0].segments)")
        expect(lines[0].segments.first?.text == "Worker One:", "w1's run should stay first")
        expect(lines[1].segments.last?.text == "[Read]", "w2's own run should be separate")
        expect(lines[2].segments.last?.text == " looking", "w2's say should follow")
    }

    private static func actionRunClosesOnTheSameWorkersNextNonAction() {
        let store = makeStore()
        feed(store, [
            entry(0, "w1", "action", "Bash"),
            entry(1, "w1", "say", "done with that"),
            entry(2, "w1", "action", "Bash"),
            entry(3, "w1", "action", "Bash"),
        ])
        let lines = entryLines(store)
        expect(lines.count == 3, "a say should close the run and the next action open a new one, got \(lines.count)")
        expect(lines[0].segments.last?.text == "[Bash]", "the closed run keeps its own count")
        expect(lines[2].segments.last?.text == "[Bash](x2)", "the new run counts only its own calls, got \(lines[2].segments)")
    }

    // MARK: - Time headers

    private static func timeHeadersFollowTheClockMinuteOfTheLastHeader() {
        let store = makeStore()
        feed(store, [
            entry(0, "w1", "say", "a"),
            entry(30, "w1", "say", "b"),
            entry(60, "w1", "say", "c"),
            entry(119, "w1", "say", "d"),
            entry(120 + 20 * 60, "w1", "say", "e"),
        ])
        let kinds = store.lines.map { line -> String in
            switch line.content {
            case .timeHeader(let label): return label
            case .entry(_, let segments): return segments.last?.text.trimmingCharacters(in: .whitespaces) ?? ""
            }
        }
        expect(kinds == ["[09:00]", "a", "b", "[09:01]", "c", "d", "[09:22]", "e"], "header placement mismatch: \(kinds)")

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let utcStore = WorkerChatStore(calendar: utc)
        feed(utcStore, [entry(0, "w1", "say", "a"), entry(59, "w1", "say", "b"), entry(60, "w1", "say", "c")])
        let utcHeaders = utcStore.lines.compactMap { line -> String? in
            guard case .timeHeader(let label) = line.content else {
                return nil
            }
            return label
        }
        expect(utcHeaders == ["[00:00]", "[00:01]"], "UTC line headers were \(utcHeaders)")
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
        expect(store.lines.count == 2, "header plus say expected, got \(store.lines.count)")

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
        expect(store.lines.count == 2, "the current feed should be visible before hiding")
        expect(store.sync(selectedSessionID: "m2", sessions: [], isVisible: false) == nil, "a hidden dock should not pull")
        expect(store.lines.count == 2, "a hidden selection change should wait to reset the visible feed")

        let otherMaster = [
            TrackerSession(id: "m2", title: "Other", repoName: "Repo", role: "master"),
            TrackerSession(id: "x1", title: "X", repoName: "Repo", agent: "codex", role: "worker", parentID: "m2"),
        ]
        let request = store.sync(selectedSessionID: "m2", sessions: otherMaster, isVisible: true)
        expect(request?.masterID == "m2" && store.lines.isEmpty, "opening on another master should reset and pull its feed")
    }

    private static func attachChangeWithinTheGroupPullsAgainKeepingCursors() {
        let store = makeStore()
        let request = store.sync(selectedSessionID: "w2", sessions: group(), isVisible: true)
        expect(request?.masterID == "m", "a worker should pull its master's feed")
        expect(store.isAttached, "a worker with a master is attached")
        let cursor = WorkerFeedCursor(offset: 7, fileID: "a")
        _ = store.receive(WorkerFeedPayload(entries: [entry(0, "w1", "say", "hi")], cursors: ["w1": cursor]), for: request!)

        var changedSibling = group()
        changedSibling[1].lastChatAt = base(1)
        let siblingChange = store.sync(selectedSessionID: "w2", sessions: changedSibling, isVisible: true)
        expect(siblingChange?.cursors == ["w1": cursor], "a selected worker should keep its sibling cursors")
        _ = store.receive(WorkerFeedPayload(), for: siblingChange!)

        let sameMaster = store.sync(selectedSessionID: "m", sessions: group(), isVisible: true)
        expect(sameMaster?.masterID == "m", "switching between a worker and its master should pull")
        expect(sameMaster?.cursors == ["w1": cursor], "the switch should keep the cursors")
        expect(store.isAttached && store.lines.count == 2, "the feed should survive the switch")
        _ = store.receive(WorkerFeedPayload(), for: sameMaster!)
        expect(store.sync(selectedSessionID: "m", sessions: group(), isVisible: true) == nil, "the same attachment should not pull again")
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
        expect(store.lines.count == 2, "the readable worker's entries should still show")
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
        let w2LinesBefore = entryLines(store).filter { $0.agent == "claude" }.map { $0.segments }
        expect(store.readNotice == "Couldn't read Worker One's activity", "the unreadable worker should have a notice before removal")

        let remainingGroup = group().filter { $0.id != "w1" }
        let next = store.sync(selectedSessionID: "m", sessions: remainingGroup, isVisible: true)
        let w2LinesAfter = entryLines(store).filter { $0.agent == "claude" }.map { $0.segments }
        expect(!entryLines(store).contains { $0.segments.first?.text == "Worker One:" }, "removed worker lines should disappear")
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

        let w2Lines = entryLines(store).filter { $0.agent == "claude" }.map { $0.segments }
        expect(!entryLines(store).contains { $0.segments.first?.text == "Worker One:" }, "removed worker entries should be dropped")
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
        expect(!entryLines(store).contains { $0.segments.first?.text == "Worker One:" }, "the final group should not show the removed worker")
        expect(entryLines(store).contains { $0.segments.last?.text == " kept" }, "the final group should keep the remaining worker")
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
        let aLines = entryLines(store).filter { $0.agent == "codex" }
        expect(aLines.count == 1 && aLines[0].segments.last?.text == "[Bash](x200)", "visible worker history should keep all 200 actions")
        expect(pending != nil, "has_more should leave one pull in flight")

        var rejoinedGroup = group()
        rejoinedGroup[2].title = ""
        expect(store.sync(selectedSessionID: "m", sessions: rejoinedGroup, isVisible: true) == nil, "re-adding should keep the existing pull")
        let bLines = entryLines(store).filter { $0.agent == "claude" }
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
        expect(store.lines.count <= WorkerChatStore.maxLines, "history should stay within \(WorkerChatStore.maxLines) lines, got \(store.lines.count)")
        if case .timeHeader = store.lines.first?.content {} else {
            fail("the first kept line should still be a time header")
        }
        expect(store.lines.last.map(lastText) == " line \(WorkerChatStore.maxLines + 99)", "the newest line should be kept")
        expect(!store.lines.contains { lastText($0) == " line 0" }, "the oldest lines should be dropped")
    }

    private static func roleAvailability() {
        expect(SessionRoleKind.master.hasWorkerChat && SessionRoleKind.worker.hasWorkerChat, "masters and workers have a chat")
        expect(!SessionRoleKind.standalone.hasWorkerChat && !SessionRoleKind.tmux.hasWorkerChat && !SessionRoleKind.orphan.hasWorkerChat, "other roles have none")
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

    private static func entryLines(_ store: WorkerChatStore) -> [(agent: String, segments: [WorkerChatSegment])] {
        store.lines.compactMap { line in
            guard case .entry(let agent, let segments) = line.content else {
                return nil
            }
            return (agent, segments)
        }
    }

    private static func segments(_ store: WorkerChatStore, _ index: Int) -> [WorkerChatSegment] {
        let lines = entryLines(store)
        return index < lines.count ? lines[index].segments : []
    }

    private static func lastText(_ line: WorkerChatLine) -> String {
        if case .entry(_, let segments) = line.content {
            return segments.last?.text ?? ""
        }
        return ""
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
