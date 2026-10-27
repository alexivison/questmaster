import Foundation
import QuestmasterCore

struct WorkerLogFilterTests {
    private static let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tokyo
        return calendar
    }

    static func run() {
        defaultShowsEverything()
        feedKindsMapToTheActionBoxes()
        summonBoxShowsSummonAndDismissLines()
        actionsAreORedWithinTheSection()
        actionAndWorkerAreANDedAcrossSections()
        tickingEveryBoxIsAnOrdinarySelection()
        newWorkerStaysHiddenUntilSelectedOrCleared()
        newWorkerStaysHiddenUnderAnAllTickedSelection()
        goneWorkersLeaveTheSelection()
        filtersAreKeptPerMaster()
        chipsShowOneNameManyCountsAndPerAgentCounts()
        clearingASectionLeavesTheOther()
        menuRowsListActionsThenWorkersInTrackerOrder()
        menuCursorMovesAndClamps()
        keysDriveTheMenu()
        filterKeysResolveOnlyWhatTheMenuStateAllows()
        filterKeepsCastRunsFolded()
        hiddenLinesStillCountTowardsTheLineTrim()
        filterChangesAreNeitherAppendsNorArrivals()
        filterHidingEveryLineLeavesNothingToList()
        print("WorkerLogFilterTests: all tests passed")
    }

    // MARK: - Selection rules

    private static func defaultShowsEverything() {
        let (store, _) = openStore(entries: sampleEntries)
        expect(store.lines.count == 5, "an empty filter should show every line, got \(store.lines.count)")
        expect(!store.filter.isActive && store.chips.isEmpty, "no selection means no filter and no chips")
        expect(store.menu == WorkerLogMenu(), "the dropdown starts closed with its cursor on the first row")
    }

    /// Cast = tool calls; Status = status; Summon = summon + dismiss; Message = say + message; Item = report + instructions.
    private static func feedKindsMapToTheActionBoxes() {
        let kinds: [(String, WorkerLogAction)] = [
            ("action", .cast), ("status", .status), ("summon", .summon), ("dismiss", .summon), ("say", .message), ("message", .message), ("report", .item), ("instructions", .item),
        ]
        for (index, (kind, expected)) in kinds.enumerated() {
            let text = kind == "status" ? "working" : "text"
            let (store, _) = openStore(entries: [entry(TimeInterval(index * 60), "w1", kind, text)])
            expect(store.lines.first?.action == expected, "\(kind) should file under \(expected), got \(String(describing: store.lines.first?.action))")
            expect(store.lines.first?.workerID == "w1", "a line should carry its worker id")
        }
    }

    private static func summonBoxShowsSummonAndDismissLines() {
        let entries = sampleEntries + [entry(300, "w1", "summon", "Explore"), entry(360, "w1", "dismiss", "Explore")]
        let (store, _) = openStore(entries: entries)
        store.toggleRow(at: row(.summon))
        expect(store.lines.map(\.action) == [.summon, .summon], "Summon alone should show the summon and the dismiss line, got \(store.lines.map(\.action))")
        expect(store.chips == [WorkerLogChip(section: .action, value: .text("Summon"))], "and name itself on the chip, got \(store.chips)")
    }

    private static func actionsAreORedWithinTheSection() {
        let (store, _) = openStore(entries: sampleEntries)
        store.toggleRow(at: row(.cast))
        store.toggleRow(at: row(.status))
        let actions = Set(store.lines.map(\.action))
        expect(actions == [.cast, .status], "Cast and Status together should show both kinds, got \(actions)")
        expect(store.lines.count == 3, "one Cast run and two status lines should show, got \(store.lines.count)")
    }

    private static func actionAndWorkerAreANDedAcrossSections() {
        let (store, _) = openStore(entries: sampleEntries)
        store.toggleRow(at: row(.status))
        store.toggleRow(at: workerRow(0))
        expect(store.lines.allSatisfy { $0.action == .status && $0.workerID == "w1" }, "Status for Worker One should show only Worker One's status lines")
        expect(store.lines.count == 1, "Worker One has one status line, got \(store.lines.count)")
        store.toggleRow(at: workerRow(1))
        expect(store.lines.count == 2, "adding Worker Two should add its status line, got \(store.lines.count)")
        expect(store.filter.workerIDs == ["w1", "w2"], "both workers ticked is the selection of those two")
    }

    /// Ticking every box is no clear: the ticks stay, the chip counts them, and only its x ends the selection.
    private static func tickingEveryBoxIsAnOrdinarySelection() {
        let (store, _) = openStore(entries: sampleEntries, workers: 3)
        WorkerLogAction.allCases.indices.forEach(store.toggleRow)
        expect(store.filter.actions == Set(WorkerLogAction.allCases) && store.filter.isActive, "every Action box ticked should keep all five ticks, got \(store.filter.actions)")
        expect(store.chips == [WorkerLogChip(section: .action, value: .text("5"))], "and show the count chip, got \(store.chips)")
        expect(store.lines.count == 5, "all five Actions still show every line, got \(store.lines.count)")

        (0..<3).forEach { store.toggleRow(at: workerRow($0)) }
        expect(store.filter.workerIDs == ["w1", "w2", "w3"], "every worker ticked should keep all three ticks, got \(store.filter.workerIDs)")
        let counts = [WorkerLogChip.AgentCount(agent: "codex", count: 2), WorkerLogChip.AgentCount(agent: "claude", count: 1)]
        expect(store.chips.last == WorkerLogChip(section: .worker, value: .agentCounts(counts)), "and show a count per agent, got \(store.chips)")
        expect(store.lines.count == 5, "every worker ticked still shows every line, got \(store.lines.count)")

        store.toggleRow(at: row(.cast))
        expect(store.filter.actions.count == WorkerLogAction.allCases.count - 1, "a tick can still come off")
        store.clearFilter(.action)
        expect(store.chips.map(\.section) == [.worker], "the Action chip's x clears the ticked section")
        store.clearFilter(.worker)
        expect(!store.filter.isActive && store.chips.isEmpty, "and the Worker chip's x the other")
    }

    /// The selected set is stored, not an excluded one, so a worker that spawns later isn't in it.
    private static func newWorkerStaysHiddenUntilSelectedOrCleared() {
        let (store, request) = openStore(entries: [], workers: 2)
        store.toggleRow(at: workerRow(0))
        expect(store.filter.workerIDs == ["w1"], "Worker One alone should be selected")

        _ = store.sync(selectedSessionID: "m", sessions: tracker(workers: 3), isVisible: true)
        _ = store.receive(WorkerFeedPayload(entries: [entry(0, "w1", "say", "from one"), entry(1, "w3", "say", "from three")]), for: request)
        expect(store.lines.map(\.workerID) == ["w1"], "the new worker should stay hidden under the Worker selection, got \(store.lines.map(\.workerID))")
        expect(store.menuRows.count == WorkerLogAction.allCases.count + 3, "the dropdown should list the new worker")

        store.toggleRow(at: workerRow(2))
        expect(store.lines.map(\.workerID) == ["w1", "w3"], "selecting the new worker should show it, got \(store.lines.map(\.workerID))")
        store.clearFilter(.worker)
        expect(store.lines.count == 2, "clearing the section shows everyone, got \(store.lines.count)")
    }

    /// Ticking every worker is a selection of those workers, so one that spawns later stays hidden as well.
    private static func newWorkerStaysHiddenUnderAnAllTickedSelection() {
        let (store, request) = openStore(entries: [], workers: 2)
        store.toggleRow(at: workerRow(0))
        store.toggleRow(at: workerRow(1))
        expect(store.filter.workerIDs == ["w1", "w2"], "both workers should stay ticked")

        _ = store.sync(selectedSessionID: "m", sessions: tracker(workers: 3), isVisible: true)
        _ = store.receive(WorkerFeedPayload(entries: [entry(0, "w1", "say", "from one"), entry(1, "w2", "say", "from two"), entry(2, "w3", "say", "from three")]), for: request)
        expect(store.lines.map(\.workerID) == ["w1", "w2"], "the new worker should stay hidden under the all-ticked selection, got \(store.lines.map(\.workerID))")
        store.toggleRow(at: workerRow(2))
        expect(store.lines.map(\.workerID) == ["w1", "w2", "w3"], "ticking it shows it, got \(store.lines.map(\.workerID))")
    }

    /// A removed worker leaves the selection, and what is left stays a selection; none left clears the section.
    private static func goneWorkersLeaveTheSelection() {
        let (store, _) = openStore(entries: [], workers: 3)
        store.toggleRow(at: workerRow(0))
        store.toggleRow(at: workerRow(1))
        _ = store.sync(selectedSessionID: "m", sessions: tracker(workers: 2), isVisible: true)
        expect(store.filter.workerIDs == ["w1", "w2"], "a worker that was never ticked going away leaves the selection as it is, got \(store.filter.workerIDs)")
        _ = store.sync(selectedSessionID: "m", sessions: tracker(workers: 3).filter { $0.id != "w1" }, isVisible: true)
        expect(store.filter.workerIDs == ["w2"], "a ticked worker going away leaves the rest ticked, got \(store.filter.workerIDs)")
        expect(store.chips.map(\.section) == [.worker], "and the chip remains")

        let (other, _) = openStore(entries: [], workers: 3)
        other.toggleRow(at: workerRow(0))
        _ = other.sync(selectedSessionID: "m", sessions: tracker(workers: 3).filter { $0.id != "w1" }, isVisible: true)
        expect(other.filter.workerIDs.isEmpty && !other.filter.isActive, "a selection of only gone workers should clear")
    }

    private static func filtersAreKeptPerMaster() {
        let store = makeStore()
        let both = tracker(workers: 2) + [
            TrackerSession(id: "m2", title: "Master Two", repoName: "Repo", role: "master"),
            TrackerSession(id: "x1", title: "Other One", repoName: "Repo", agent: "codex", role: "worker", parentID: "m2"),
            TrackerSession(id: "x2", title: "Other Two", repoName: "Repo", agent: "claude", role: "worker", parentID: "m2"),
        ]
        _ = store.sync(selectedSessionID: "m", sessions: both, isVisible: true)
        store.toggleRow(at: row(.status))
        store.toggleRow(at: workerRow(1))
        let first = store.filter

        _ = store.sync(selectedSessionID: "m2", sessions: both, isVisible: true)
        expect(!store.filter.isActive, "another master starts unfiltered, got \(store.filter)")
        store.toggleRow(at: row(.item))
        expect(store.filter.actions == [.item], "the second master keeps its own filter")

        _ = store.sync(selectedSessionID: "m", sessions: both, isVisible: true)
        expect(store.filter == first, "switching back should restore the first master's filter, got \(store.filter)")
        _ = store.sync(selectedSessionID: "m-w", sessions: both + [TrackerSession(id: "m-w", title: "Shell", repoName: "Repo", role: "shell")], isVisible: true)
        _ = store.sync(selectedSessionID: "m", sessions: both, isVisible: true)
        expect(store.filter == first, "attaching to a non-master in between should not lose it")
        _ = store.sync(selectedSessionID: "m2", sessions: both, isVisible: true)
        expect(store.filter.actions == [.item], "and the second master's filter should still be there")
    }

    // MARK: - Chips

    private static func chipsShowOneNameManyCountsAndPerAgentCounts() {
        let workers = [
            WorkerLogWorker(id: "a", name: "Alpha", agent: "claude"),
            WorkerLogWorker(id: "b", name: "Beta", agent: "codex"),
            WorkerLogWorker(id: "c", name: "Gamma", agent: "claude"),
            WorkerLogWorker(id: "d", name: "Delta", agent: "codex"),
            WorkerLogWorker(id: "e", name: "Epsilon", agent: "codex"),
        ]
        var filter = WorkerLogFilter()
        expect(filter.chips(workers: workers).isEmpty, "no selection, no chips")

        filter.toggle(.status)
        expect(filter.chips(workers: workers) == [WorkerLogChip(section: .action, value: .text("Status"))], "one action shows its name")
        filter.toggle(.message)
        filter.toggle(.item)
        expect(filter.chips(workers: workers) == [WorkerLogChip(section: .action, value: .text("3"))], "several actions show their count")

        filter.toggle(workers[1])
        expect(
            filter.chips(workers: workers).last == WorkerLogChip(section: .worker, value: .worker(name: "Beta", agent: "codex")),
            "one worker shows its logo and name"
        )
        filter.toggle(workers[0])
        filter.toggle(workers[2])
        filter.toggle(workers[3])
        let counts = [WorkerLogChip.AgentCount(agent: "claude", count: 2), WorkerLogChip.AgentCount(agent: "codex", count: 2)]
        expect(
            filter.chips(workers: workers) == [WorkerLogChip(section: .action, value: .text("3")), WorkerLogChip(section: .worker, value: .agentCounts(counts))],
            "several workers show a count per agent, in the tracker's order, after the Action chip: \(filter.chips(workers: workers))"
        )
        expect(WorkerLogChip(section: .action, value: .text("")).title == "Action" && WorkerLogChip(section: .worker, value: .text("")).title == "Worker", "chip titles")
    }

    private static func clearingASectionLeavesTheOther() {
        let (store, _) = openStore(entries: sampleEntries)
        store.toggleRow(at: row(.status))
        store.toggleRow(at: workerRow(0))
        store.clearFilter(.action)
        expect(store.filter.actions.isEmpty && store.filter.workerIDs == ["w1"], "the Action chip's x clears only Actions")
        expect(store.chips.map(\.section) == [.worker], "only the Worker chip should remain, got \(store.chips)")
        store.clearFilter(.worker)
        expect(!store.filter.isActive && store.chips.isEmpty, "clearing the last section ends the filter")
        expect(store.lines.count == 5, "the cleared filter shows everything again, got \(store.lines.count)")
    }

    // MARK: - Dropdown

    private static func menuRowsListActionsThenWorkersInTrackerOrder() {
        let (store, _) = openStore(entries: [], workers: 3)
        let titles = store.menuRows.map { row -> String in
            switch row {
            case .action(let action): action.title
            case .worker(let worker): worker.name
            }
        }
        expect(titles == ["Cast", "Status", "Summon", "Message", "Item", "Worker One", "Worker Two", "Worker Three"], "rows should list the boxes, then the workers in tracker order, got \(titles)")
    }

    private static func menuCursorMovesAndClamps() {
        var menu = WorkerLogMenu()
        menu.moveCursor(by: -1, rowCount: 6)
        expect(menu.cursor == 0, "the cursor stops at the first row")
        (0..<10).forEach { _ in menu.moveCursor(by: 1, rowCount: 6) }
        expect(menu.cursor == 5, "the cursor stops at the last row, got \(menu.cursor)")
        menu.clampCursor(rowCount: 4)
        expect(menu.cursor == 3, "fewer rows pull the cursor back, got \(menu.cursor)")
        menu.setCursor(9, rowCount: 4)
        expect(menu.cursor == 3, "a row that isn't there takes no cursor")
        menu.toggleOpen()
        expect(menu.isOpen && menu.cursor == 0, "opening puts the cursor on the first row")
        menu.moveCursor(by: 0, rowCount: 0)
        menu.close()
        expect(!menu.isOpen, "close closes")
    }

    private static func keysDriveTheMenu() {
        let (store, _) = openStore(entries: sampleEntries)
        expect(!store.handle(.moveDown) && !store.handle(.toggleRow) && !store.handle(.close), "a closed dropdown takes no cursor, toggle or close keys")
        expect(store.handle(.toggleMenu) && store.menu.isOpen, "f opens the dropdown")
        expect(store.handle(.moveDown) && store.menu.cursor == 1, "j moves the cursor down")
        expect(store.handle(.toggleRow), "Space toggles")
        expect(store.filter.actions == [.status], "the row under the cursor toggled, got \(store.filter.actions)")
        expect(store.menu.isOpen, "the dropdown stays open while toggling")
        expect(store.handle(.moveUp) && store.menu.cursor == 0, "k moves the cursor up")
        expect(store.handle(.toggleRow) && store.filter.actions == [.status, .cast], "Return toggles the next row too, got \(store.filter.actions)")
        store.toggleRow(at: workerRow(1))
        expect(store.menu.cursor == workerRow(1), "a click puts the cursor on its row")
        expect(store.filter.workerIDs == ["w2"], "and toggles it")
        expect(store.handle(.close) && !store.menu.isOpen, "Esc closes")
        expect(store.filter.isActive, "closing keeps the filter")
        expect(store.handle(.toggleMenu) && store.menu.isOpen && store.menu.cursor == 0, "f reopens with the cursor on the first row")
        expect(store.handle(.toggleMenu) && !store.menu.isOpen, "f closes it again")

        let detached = makeStore()
        _ = detached.sync(selectedSessionID: "shell", sessions: [TrackerSession(id: "shell", title: "Shell", repoName: "Repo", role: "shell")], isVisible: true)
        expect(!detached.handle(.toggleMenu) && !detached.menu.isOpen, "a session with no workers to log has no filter to open")
    }

    private static func filterKeysResolveOnlyWhatTheMenuStateAllows() {
        func resolve(_ keyCode: UInt16, _ character: String?, open: Bool) -> WorkerLogFilterKey? {
            WorkerLogFilterKey.resolve(keyCode: keyCode, character: character, menuIsOpen: open)
        }
        expect(resolve(3, "f", open: false) == .toggleMenu && resolve(3, "f", open: true) == .toggleMenu, "f toggles in both states")
        expect(resolve(38, "j", open: false) == nil && resolve(126, nil, open: false) == nil, "the cursor keys mean nothing while closed")
        expect(resolve(38, "j", open: true) == .moveDown && resolve(125, nil, open: true) == .moveDown, "j and ↓ move down")
        expect(resolve(40, "k", open: true) == .moveUp && resolve(126, nil, open: true) == .moveUp, "k and ↑ move up")
        expect(resolve(49, " ", open: true) == .toggleRow && resolve(36, "\r", open: true) == .toggleRow && resolve(76, nil, open: true) == .toggleRow, "Space and Return toggle")
        expect(resolve(53, nil, open: true) == .close && resolve(53, nil, open: false) == nil, "Esc closes an open dropdown only")
        expect(resolve(0, "a", open: true) == nil, "other keys are not the filter's")
    }

    // MARK: - Feed behaviour

    /// Hidden lines don't change what folds: a Cast run is cut by a same-worker message the filter hides, as it is unfiltered.
    private static func filterKeepsCastRunsFolded() {
        let entries = [
            entry(0, "w1", "action", "Bash"), entry(1, "w1", "action", "Bash"),
            entry(2, "w1", "say", "narration"),
            entry(3, "w1", "action", "Edit"),
        ]
        let (store, _) = openStore(entries: entries)
        expect(store.lines.count == 3, "unfiltered: a run, a message, a run, got \(store.lines.count)")
        store.toggleRow(at: row(.cast))
        let tools = store.lines.compactMap { $0.segments.last?.text }
        expect(tools == ["[Bash](x2)", "[Edit]"], "the message still cuts the run while hidden, got \(tools)")
    }

    /// The 600/500 trim counts every built line, shown or not, so a filter never changes what history is kept, and a
    /// trim of hidden lines changes nothing on screen.
    private static func hiddenLinesStillCountTowardsTheLineTrim() {
        let entries = (0...WorkerChatStore.maxLines).map { entry(TimeInterval($0 * 60), "w1", "action", "Bash") }
        let (store, request) = openStore(entries: [], workers: 2)
        store.toggleRow(at: row(.status))
        let revision = store.revision
        _ = store.receive(WorkerFeedPayload(entries: entries), for: request)
        expect(store.lines.isEmpty, "the Status filter hides every Cast line")
        expect(store.trimCount == 0, "a trim that only dropped hidden lines should not count, got \(store.trimCount)")
        expect(store.revision == revision, "and the screen didn't change, so neither did the revision")

        store.clearFilter(.action)
        expect(store.lines.count == WorkerChatStore.trimTarget, "the history was trimmed as if unfiltered: \(store.lines.count) lines")
        expect(store.lines.first?.time == "10:41", "the oldest kept line should be 10:41, got \(String(describing: store.lines.first?.time))")
    }

    private static func filterChangesAreNeitherAppendsNorArrivals() {
        let (store, request) = openStore(entries: [entry(0, "w1", "say", "one")], workers: 2)
        let revision = store.revision
        let trims = store.trimCount
        store.toggleRow(at: row(.status))
        expect(store.revision == revision + 1, "a filter change replaces the lines")
        expect(!store.lastUpdateAppended, "a filter change is no append, so nothing fades in")
        expect(store.trimCount == trims + 1, "and it glides no more than a trim does")

        let hidden = store.revision
        _ = store.receive(WorkerFeedPayload(entries: [entry(10, "w1", "say", "hidden arrival")]), for: request)
        expect(store.revision == hidden, "an arrival the filter hides changes nothing on screen")

        _ = store.receive(WorkerFeedPayload(entries: [entry(20, "w1", "status", "working")]), for: request)
        expect(store.lastUpdateAppended && store.lines.count == 1, "an arrival it shows is an append")
    }

    /// The panel draws its empty icon when `isKnownEmpty`: a feed that has lines but none the filter shows is empty to the
    /// reader, while a first read still on its way is blank, filter or not.
    private static func filterHidingEveryLineLeavesNothingToList() {
        let (store, request) = openStore(entries: [entry(0, "w1", "say", "one")])
        expect(!store.isKnownEmpty, "a feed showing a line is not empty")
        store.toggleRow(at: row(.status))
        expect(store.lines.isEmpty && store.isKnownEmpty, "a filter that hides every line leaves nothing to list")
        expect(store.chips.count == 1, "and the chip that did it stays, so its x can clear it")
        _ = store.receive(WorkerFeedPayload(entries: [entry(10, "w1", "say", "also hidden")]), for: request)
        expect(store.isKnownEmpty, "a hidden arrival changes nothing")
        store.clearFilter(.action)
        expect(!store.isKnownEmpty && store.lines.count == 2, "clearing the filter shows the lines again")

        let partial = makeStore()
        let partialRequest = partial.sync(selectedSessionID: "m", sessions: tracker(workers: 2), isVisible: true)
        _ = partial.receive(WorkerFeedPayload(entries: [entry(0, "w1", "say", "one")], hasMore: ["w1": true]), for: partialRequest!)
        partial.toggleRow(at: row(.status))
        expect(partial.lines.isEmpty && partial.isKnownEmpty, "a feed with lines the filter hides is empty to the reader even with more to read")

        let pending = makeStore()
        _ = pending.sync(selectedSessionID: "m", sessions: tracker(workers: 2), isVisible: true)
        pending.toggleRow(at: row(.status))
        expect(pending.filter.isActive && !pending.isKnownEmpty, "a filter set while the first read is pending is blank, not empty")
    }

    // MARK: - Helpers

    /// Worker One: say, status, Bash x2. Worker Two: report, status.
    private static var sampleEntries: [WorkerFeedEntry] {
        [
            entry(0, "w1", "say", "hello"),
            entry(60, "w1", "status", "working"),
            entry(120, "w1", "action", "Bash"),
            entry(121, "w1", "action", "Bash"),
            entry(180, "w2", "report", "done"),
            entry(240, "w2", "status", "done"),
        ]
    }

    /// The row index of an Action box.
    private static func row(_ action: WorkerLogAction) -> Int {
        WorkerLogAction.allCases.firstIndex(of: action) ?? -1
    }

    /// The row index of the worker at `position` in tracker order.
    private static func workerRow(_ position: Int) -> Int {
        WorkerLogAction.allCases.count + position
    }

    private static func makeStore() -> WorkerChatStore {
        WorkerChatStore(calendar: calendar)
    }

    private static func tracker(workers count: Int) -> [TrackerSession] {
        let names = ["Worker One", "Worker Two", "Worker Three"]
        let agents = ["codex", "claude", "codex"]
        return [TrackerSession(id: "m", title: "Master", repoName: "Repo", agent: "claude", role: "master")]
            + (0..<count).map { index in
                TrackerSession(id: "w\(index + 1)", title: names[index], repoName: "Repo", agent: agents[index], role: "worker", parentID: "m")
            }
    }

    /// A store attached to master `m` with `workers` workers and `entries` applied. Later payloads can answer the same
    /// request, as the other worker chat tests do.
    private static func openStore(entries: [WorkerFeedEntry], workers: Int = 2) -> (WorkerChatStore, WorkerFeedRequest) {
        let store = makeStore()
        guard let request = store.sync(selectedSessionID: "m", sessions: tracker(workers: workers), isVisible: true) else {
            fail("opening the dock should have produced a request")
        }
        _ = store.receive(WorkerFeedPayload(entries: entries), for: request)
        return (store, request)
    }

    private static func base(_ seconds: TimeInterval) -> Date {
        DateComponents(calendar: calendar, timeZone: tokyo, year: 2026, month: 10, day: 7, hour: 9).date!.addingTimeInterval(seconds)
    }

    private static func entry(_ seconds: TimeInterval, _ worker: String, _ kind: String, _ text: String) -> WorkerFeedEntry {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return WorkerFeedEntry(
            timestamp: formatter.string(from: base(seconds)),
            workerID: worker,
            workerTitle: worker == "w1" ? "Worker One" : "Worker Two",
            kind: kind,
            text: text
        )
    }

    private static func fail(_ message: String) -> Never {
        fputs("WorkerLogFilterTests failed: \(message)\n", stderr)
        Foundation.exit(1)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fail(message)
        }
    }
}
