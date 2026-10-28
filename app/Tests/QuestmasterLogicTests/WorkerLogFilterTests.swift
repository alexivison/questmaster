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
        actionBoxesAreAlphabetical()
        feedKindsMapToTheActionBoxes()
        summonBoxShowsSummonAndDismissLines()
        actionsAreORedWithinTheSection()
        actionAndWorkerTabAreANDed()
        tickingEveryBoxIsAnOrdinarySelection()
        aWorkerTabShowsOnlyItsLines()
        aNewWorkerShowsUnderAllAndItsOwnTab()
        aGoneWorkerFallsBackToAll()
        selectingAnUnknownWorkerDoesNothing()
        filtersAreKeptPerMaster()
        actionSummaryNamesTheTicksInTheDropdownsOrder()
        clearingTheActionsKeepsTheWorkerTab()
        workersListInTrackerOrder()
        tabsMoveAndWrapLikeTheSettingsTabs()
        menuCursorMovesAndClamps()
        keysDriveTheMenu()
        tabKeysSwitchTabsWithTheMenuOpenOrClosed()
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
        expect(!narrows(store.filter) && store.filter.actionSummary == nil && store.filter.workerID == nil, "no selection means no filter, no chip and the All tab")
        expect(store.menu == WorkerLogMenu(), "the dropdown starts closed with its cursor on the first row")
    }

    /// Cast = tool calls; Status = status; Summon = summon + dismiss; Message = say + message; Item = report + instructions.
    /// The boxes are alphabetical, in the dropdown and so on the chip.
    private static func actionBoxesAreAlphabetical() {
        let titles = WorkerLogAction.allCases.map(\.title)
        expect(titles == ["Cast", "Item", "Message", "Status", "Summon"], "the boxes should be listed Cast, Item, Message, Status, Summon, got \(titles)")
        expect(titles == titles.sorted(), "and in alphabetical order")
    }

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
        store.toggleAction(at: row(.summon))
        expect(store.lines.map(\.action) == [.summon, .summon], "Summon alone should show the summon and the dismiss line, got \(store.lines.map(\.action))")
        expect(store.filter.actionSummary == "Summon", "and name itself on the chip, got \(String(describing: store.filter.actionSummary))")
    }

    private static func actionsAreORedWithinTheSection() {
        let (store, _) = openStore(entries: sampleEntries)
        store.toggleAction(at: row(.cast))
        store.toggleAction(at: row(.status))
        let actions = Set(store.lines.map(\.action))
        expect(actions == [.cast, .status], "Cast and Status together should show both kinds, got \(actions)")
        expect(store.lines.count == 3, "one Cast run and two status lines should show, got \(store.lines.count)")
    }

    /// The Action ticks and the worker tab both have to allow a line.
    private static func actionAndWorkerTabAreANDed() {
        let (store, _) = openStore(entries: sampleEntries)
        store.toggleAction(at: row(.status))
        store.selectWorker("w1")
        expect(store.lines.allSatisfy { $0.action == .status && $0.workerID == "w1" }, "Status on Worker One's tab should show only Worker One's status lines")
        expect(store.lines.count == 1, "Worker One has one status line, got \(store.lines.count)")
        store.selectWorker("w2")
        expect(store.lines.map(\.workerID) == ["w2"] && store.lines.allSatisfy { $0.action == .status }, "Worker Two's tab shows its own status line, not Worker One's")
        store.selectWorker(nil)
        expect(store.lines.count == 2, "the All tab shows every worker's status lines again, got \(store.lines.count)")
        expect(store.filter.actions == [.status], "and the tab change leaves the Action ticks alone")
    }

    /// Ticking every box is no clear: the ticks stay, the chip counts them, and only its x ends the selection.
    private static func tickingEveryBoxIsAnOrdinarySelection() {
        let (store, _) = openStore(entries: sampleEntries, workers: 3)
        WorkerLogAction.allCases.indices.forEach(store.toggleAction)
        expect(store.filter.actions == Set(WorkerLogAction.allCases) && narrows(store.filter), "every Action box ticked should keep all five ticks, got \(store.filter.actions)")
        expect(store.filter.actionSummary == "Cast, Item, Message, Status, Summon", "and name them all on the chip, got \(String(describing: store.filter.actionSummary))")
        expect(store.lines.count == 5, "all five Actions still show every line, got \(store.lines.count)")

        store.toggleAction(at: row(.cast))
        expect(store.filter.actions.count == WorkerLogAction.allCases.count - 1, "a tick can still come off")
        store.clearActions()
        expect(!narrows(store.filter) && store.filter.actionSummary == nil, "the chip's x clears the ticks")
    }

    /// One tab at a time: a worker's tab shows only that worker's lines, a second selection replaces the first, All shows everyone.
    private static func aWorkerTabShowsOnlyItsLines() {
        let (store, _) = openStore(entries: sampleEntries)
        store.selectWorker("w1")
        expect(store.filter.workerID == "w1" && narrows(store.filter), "Worker One's tab should be selected")
        expect(store.lines.map(\.workerID) == ["w1", "w1", "w1"], "Worker One's tab shows its three lines, got \(store.lines.map(\.workerID))")
        store.selectWorker("w2")
        expect(store.filter.workerID == "w2" && store.lines.map(\.workerID) == ["w2", "w2"], "Worker Two's tab replaces the first and shows its two lines")
        store.selectWorker(nil)
        expect(store.filter.workerID == nil && !narrows(store.filter) && store.lines.count == 5, "the All tab shows every line and is no filter")
    }

    /// A tab selects one worker, so a worker that spawns later is under All and its own tab, and not under another's.
    private static func aNewWorkerShowsUnderAllAndItsOwnTab() {
        let (store, request) = openStore(entries: [], workers: 2)
        store.selectWorker("w1")
        _ = store.sync(selectedSessionID: "m", sessions: tracker(workers: 3), isVisible: true)
        _ = store.receive(WorkerFeedPayload(entries: [entry(0, "w1", "say", "from one"), entry(1, "w3", "say", "from three")]), for: request)
        expect(store.lines.map(\.workerID) == ["w1"], "the new worker is not under another worker's tab, got \(store.lines.map(\.workerID))")
        expect(store.workers.map(\.id) == ["w1", "w2", "w3"], "but it has a tab")
        store.selectWorker("w3")
        expect(store.lines.map(\.workerID) == ["w3"], "its own tab shows it, got \(store.lines.map(\.workerID))")
        store.selectWorker(nil)
        expect(store.lines.map(\.workerID) == ["w1", "w3"], "and All shows it, got \(store.lines.map(\.workerID))")
    }

    /// The selected worker going away falls back to All; any other worker going away leaves the tab alone.
    private static func aGoneWorkerFallsBackToAll() {
        let (store, _) = openStore(entries: sampleEntries, workers: 3)
        store.selectWorker("w2")
        _ = store.sync(selectedSessionID: "m", sessions: tracker(workers: 3).filter { $0.id != "w3" }, isVisible: true)
        expect(store.filter.workerID == "w2", "another worker going away should leave the selected tab, got \(String(describing: store.filter.workerID))")
        _ = store.sync(selectedSessionID: "m", sessions: tracker(workers: 3).filter { $0.id == "m" || $0.id == "w1" }, isVisible: true)
        expect(store.filter.workerID == nil && !narrows(store.filter), "the selected worker going away should fall back to All, got \(String(describing: store.filter.workerID))")
        expect(store.lines.map(\.workerID).allSatisfy { $0 == "w1" } && store.lines.count == 3, "and show what is left, got \(store.lines.map(\.workerID))")

        let (ticked, _) = openStore(entries: sampleEntries, workers: 2)
        ticked.toggleAction(at: row(.status))
        ticked.selectWorker("w1")
        _ = ticked.sync(selectedSessionID: "m", sessions: tracker(workers: 2).filter { $0.id != "w1" }, isVisible: true)
        expect(ticked.filter.workerID == nil && ticked.filter.actions == [.status], "falling back to All keeps the Action ticks")
    }

    private static func selectingAnUnknownWorkerDoesNothing() {
        let (store, _) = openStore(entries: sampleEntries)
        let revision = store.revision
        store.selectWorker("gone")
        expect(store.filter.workerID == nil && store.revision == revision, "a worker that isn't the master's selects nothing")
        let detached = makeStore()
        detached.selectWorker("w1")
        detached.moveTab(by: 1)
        expect(!narrows(detached.filter), "nothing attached has no tab to select")
    }

    /// The Action ticks are app-wide: every master shares one selection, and switching masters keeps it. The worker tab names
    /// one master's workers, so each master has its own.
    private static func filtersAreKeptPerMaster() {
        let store = makeStore()
        let both = tracker(workers: 2) + [
            TrackerSession(id: "m2", title: "Master Two", repoName: "Repo", role: "master"),
            TrackerSession(id: "x1", title: "Other One", repoName: "Repo", agent: "codex", role: "worker", parentID: "m2"),
            TrackerSession(id: "x2", title: "Other Two", repoName: "Repo", agent: "claude", role: "worker", parentID: "m2"),
            TrackerSession(id: "sh", title: "Shell", repoName: "Repo", role: "shell"),
        ]
        _ = store.sync(selectedSessionID: "m", sessions: both, isVisible: true)
        store.toggleAction(at: row(.status))
        store.selectWorker("w2")

        _ = store.sync(selectedSessionID: "m2", sessions: both, isVisible: true)
        expect(store.filter.actions == [.status], "another master keeps the Action ticks, got \(store.filter.actions)")
        expect(store.filter.workerID == nil, "but starts on the All tab, got \(String(describing: store.filter.workerID))")
        store.toggleAction(at: row(.item))
        store.selectWorker("x1")
        expect(store.filter.actions == [.status, .item] && store.filter.workerID == "x1", "the second master adds to the shared ticks and picks its own tab")

        _ = store.sync(selectedSessionID: "m", sessions: both, isVisible: true)
        expect(store.filter.actions == [.status, .item], "switching back keeps the ticks made meanwhile, got \(store.filter.actions)")
        expect(store.filter.workerID == "w2", "and restores the first master's tab, got \(String(describing: store.filter.workerID))")
        store.clearActions()
        _ = store.sync(selectedSessionID: "m2", sessions: both, isVisible: true)
        expect(store.filter.actions.isEmpty && store.filter.workerID == "x1", "clearing the ticks clears them for every master, and the second master's tab is still there")

        store.toggleAction(at: row(.cast))
        _ = store.sync(selectedSessionID: "sh", sessions: both, isVisible: true)
        expect(!store.isAttached && store.filter.actions == [.cast] && store.filter.workerID == nil, "attaching to a non-master keeps the ticks and has no tab")
        _ = store.sync(selectedSessionID: "m", sessions: both, isVisible: true)
        expect(store.filter.actions == [.cast] && store.filter.workerID == "w2", "coming back restores the master's tab with the ticks as they are")
        _ = store.sync(selectedSessionID: "m2", sessions: both, isVisible: true)
        expect(store.filter.actions == [.cast] && store.filter.workerID == "x1", "and the other master's tab too")

        let tabOnly = makeStore()
        _ = tabOnly.sync(selectedSessionID: "m", sessions: both, isVisible: true)
        tabOnly.selectWorker("w1")
        _ = tabOnly.sync(selectedSessionID: "m2", sessions: both, isVisible: true)
        _ = tabOnly.sync(selectedSessionID: "m", sessions: both, isVisible: true)
        expect(tabOnly.filter.workerID == "w1", "a selected tab alone is remembered")

        let fresh = makeStore()
        _ = fresh.sync(selectedSessionID: "m", sessions: both, isVisible: true)
        expect(fresh.filter.actions.isEmpty, "a new store has no ticks: nothing is kept past the store")
    }

    // MARK: - Chip and tabs

    /// The chip names the ticked actions, comma-separated in `WorkerLogAction.allCases` order, whatever order they were ticked in.
    private static func actionSummaryNamesTheTicksInTheDropdownsOrder() {
        var filter = WorkerLogFilter()
        expect(filter.actionSummary == nil, "no ticks, no chip")
        filter.toggle(.status)
        expect(filter.actionSummary == "Status", "one action shows its name")
        filter.toggle(.item)
        filter.toggle(.message)
        let ticked: Set<WorkerLogAction> = [.status, .item, .message]
        let inDropdownOrder = WorkerLogAction.allCases.filter(ticked.contains).map(\.title).joined(separator: ", ")
        expect(filter.actionSummary == inDropdownOrder, "several actions list their names in the dropdown's order, got \(String(describing: filter.actionSummary))")
        expect(filter.actionSummary == "Item, Message, Status", "which is alphabetical: Item, Message, Status")
        filter.toggle(.status)
        expect(filter.actionSummary == "Item, Message", "unticking one drops its name")
        WorkerLogAction.allCases.forEach { action in
            if !filter.actions.contains(action) {
                filter.toggle(action)
            }
        }
        expect(filter.actionSummary == WorkerLogAction.allCases.map(\.title).joined(separator: ", "), "every action ticked lists all five")
        filter.clearActions()
        expect(filter.actionSummary == nil, "clearing the ticks takes the chip away")
        filter.toggle(.cast)
        filter.selectWorker("w1")
        expect(filter.actionSummary == "Cast", "the worker tab is no part of the chip")
    }

    private static func clearingTheActionsKeepsTheWorkerTab() {
        let (store, _) = openStore(entries: sampleEntries)
        store.toggleAction(at: row(.status))
        store.selectWorker("w1")
        store.clearActions()
        expect(store.filter.actions.isEmpty && store.filter.workerID == "w1", "the chip's x clears only the Action ticks")
        expect(narrows(store.filter) && store.lines.count == 3, "the tab still narrows the log, got \(store.lines.count) lines")
        store.selectWorker(nil)
        expect(!narrows(store.filter) && store.lines.count == 5, "the All tab ends the filter")
    }

    private static func workersListInTrackerOrder() {
        let (store, _) = openStore(entries: [], workers: 3)
        expect(store.workers.map(\.name) == ["Worker One", "Worker Two", "Worker Three"], "the tabs after All should be the workers in tracker order, got \(store.workers.map(\.name))")
        expect(store.workers.map(\.id) == ["w1", "w2", "w3"], "with their ids")
        let alone = makeStore()
        _ = alone.sync(selectedSessionID: "m", sessions: [TrackerSession(id: "m", title: "Master", repoName: "Repo", role: "master")], isVisible: true)
        expect(alone.workers.isEmpty, "a master with no workers has no tabs")
    }

    /// The Settings tabs' `moveTab`: one step, wrapping past either end. All is the first tab.
    private static func tabsMoveAndWrapLikeTheSettingsTabs() {
        let workers = [WorkerLogWorker(id: "a", name: "Alpha"), WorkerLogWorker(id: "b", name: "Beta")]
        var filter = WorkerLogFilter()
        expect(filter.tabIndex(in: workers) == 0, "nothing selected is the All tab")
        filter.moveTab(1, in: workers)
        expect(filter.workerID == "a" && filter.tabIndex(in: workers) == 1, "next from All is the first worker")
        filter.moveTab(1, in: workers)
        expect(filter.workerID == "b" && filter.tabIndex(in: workers) == 2, "next again is the second")
        filter.moveTab(1, in: workers)
        expect(filter.workerID == nil, "next past the last wraps to All")
        filter.moveTab(-1, in: workers)
        expect(filter.workerID == "b", "previous from All wraps to the last worker")
        filter.moveTab(-1, in: workers)
        expect(filter.workerID == "a", "previous steps back")
        filter.moveTab(-1, in: workers)
        expect(filter.workerID == nil, "previous from the first worker is All")

        var empty = WorkerLogFilter()
        empty.moveTab(1, in: [])
        expect(empty.workerID == nil, "no workers, no tabs to move")
        var stale = WorkerLogFilter()
        stale.selectWorker("gone")
        expect(stale.tabIndex(in: workers) == 0, "a selection that is not among the workers counts as All")
    }

    // MARK: - Dropdown

    private static func menuCursorMovesAndClamps() {
        var menu = WorkerLogMenu()
        menu.moveCursor(by: -1, rowCount: 5)
        expect(menu.cursor == 0, "the cursor stops at the first row")
        (0..<10).forEach { _ in menu.moveCursor(by: 1, rowCount: 5) }
        expect(menu.cursor == 4, "the cursor stops at the last row, got \(menu.cursor)")
        menu.setCursor(9, rowCount: 5)
        expect(menu.cursor == 4, "a row that isn't there takes no cursor")
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
        expect(store.filter.actions == [.item], "the row under the cursor toggled, got \(store.filter.actions)")
        expect(store.menu.isOpen, "the dropdown stays open while toggling")
        expect(store.handle(.moveUp) && store.menu.cursor == 0, "k moves the cursor up")
        expect(store.handle(.toggleRow) && store.filter.actions == [.item, .cast], "Return toggles the next row too, got \(store.filter.actions)")
        store.toggleAction(at: row(.status))
        expect(store.menu.cursor == row(.status), "a click puts the cursor on its row")
        expect(store.filter.actions == [.item, .cast, .status], "and toggles it")
        (0..<10).forEach { _ in _ = store.handle(.moveDown) }
        expect(store.menu.cursor == WorkerLogAction.allCases.count - 1, "the cursor stops at the last Action row, got \(store.menu.cursor)")
        expect(store.handle(.close) && !store.menu.isOpen, "Esc closes")
        expect(narrows(store.filter), "closing keeps the filter")
        expect(store.handle(.toggleMenu) && store.menu.isOpen && store.menu.cursor == 0, "f reopens with the cursor on the first row")
        expect(store.handle(.toggleMenu) && !store.menu.isOpen, "f closes it again")

        let detached = makeStore()
        _ = detached.sync(selectedSessionID: "shell", sessions: [TrackerSession(id: "shell", title: "Shell", repoName: "Repo", role: "shell")], isVisible: true)
        expect(!detached.handle(.toggleMenu) && !detached.menu.isOpen, "a session with no workers to log has no filter to open")
    }

    /// `[` and `]` step the tabs whether the dropdown is open or not, leaving it as it is; with no workers there is no tab row,
    /// so they are not the log's keys.
    private static func tabKeysSwitchTabsWithTheMenuOpenOrClosed() {
        let (store, _) = openStore(entries: sampleEntries)
        expect(store.handle(.nextTab) && store.filter.workerID == "w1", "] selects the first worker with the dropdown closed")
        expect(store.handle(.nextTab) && store.filter.workerID == "w2", "] again selects the next")
        expect(store.lines.map(\.workerID) == ["w2", "w2"], "the log follows the tab, got \(store.lines.map(\.workerID))")
        expect(store.handle(.nextTab) && store.filter.workerID == nil, "] wraps from the last worker to All")
        expect(store.handle(.previousTab) && store.filter.workerID == "w2", "[ wraps from All to the last worker")
        expect(!store.menu.isOpen, "the tab keys don't open the dropdown")

        _ = store.handle(.toggleMenu)
        expect(store.handle(.previousTab) && store.filter.workerID == "w1", "[ still steps the tabs with the dropdown open")
        expect(store.menu.isOpen && store.menu.cursor == 0, "and leaves the dropdown open where it was")

        let alone = makeStore()
        _ = alone.sync(selectedSessionID: "m", sessions: [TrackerSession(id: "m", title: "Master", repoName: "Repo", role: "master")], isVisible: true)
        expect(!alone.handle(.nextTab) && !alone.handle(.previousTab), "a master with no workers has no tabs to step")
        let detached = makeStore()
        expect(!detached.handle(.nextTab), "nothing attached has none either")
    }

    private static func filterKeysResolveOnlyWhatTheMenuStateAllows() {
        func resolve(_ keyCode: UInt16, _ character: String?, open: Bool) -> WorkerLogFilterKey? {
            WorkerLogFilterKey.resolve(keyCode: keyCode, character: character, menuIsOpen: open)
        }
        expect(resolve(3, "f", open: false) == .toggleMenu && resolve(3, "f", open: true) == .toggleMenu, "f toggles in both states")
        expect(resolve(33, "[", open: false) == .previousTab && resolve(33, "[", open: true) == .previousTab, "[ steps back in both states")
        expect(resolve(30, "]", open: false) == .nextTab && resolve(30, "]", open: true) == .nextTab, "] steps forward in both states")
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
        store.toggleAction(at: row(.cast))
        let tools = store.lines.compactMap { $0.segments.last?.text }
        expect(tools == ["[Bash](x2)", "[Edit]"], "the message still cuts the run while hidden, got \(tools)")
    }

    /// The line trim counts every built line, shown or not, so a filter never changes what history is kept, and a
    /// trim of hidden lines changes nothing on screen.
    private static func hiddenLinesStillCountTowardsTheLineTrim() {
        let entries = (0...WorkerChatStore.maxLines).map { entry(TimeInterval($0 * 60), "w1", "action", "Bash") }
        let (store, request) = openStore(entries: [], workers: 2)
        store.toggleAction(at: row(.status))
        let revision = store.revision
        _ = store.receive(WorkerFeedPayload(entries: entries), for: request)
        expect(store.lines.isEmpty, "the Status filter hides every Cast line")
        expect(store.trimCount == 0, "a trim that only dropped hidden lines should not count, got \(store.trimCount)")
        expect(store.revision == revision, "and the screen didn't change, so neither did the revision")

        store.clearActions()
        expect(store.lines.count == WorkerChatStore.trimTarget, "the history was trimmed as if unfiltered: \(store.lines.count) lines")
        let oldestKept = WorkerChatTests.clock(minutes: WorkerChatStore.maxLines + 1 - WorkerChatStore.trimTarget)
        expect(store.lines.first?.time == oldestKept, "the oldest kept line should be \(oldestKept), got \(String(describing: store.lines.first?.time))")
    }

    private static func filterChangesAreNeitherAppendsNorArrivals() {
        let (store, request) = openStore(entries: [entry(0, "w1", "say", "one")], workers: 2)
        let revision = store.revision
        let trims = store.trimCount
        store.toggleAction(at: row(.status))
        expect(store.revision == revision + 1, "a filter change replaces the lines")
        expect(!store.lastUpdateAppended, "a filter change is no append, so nothing fades in")
        expect(store.trimCount == trims + 1, "and it glides no more than a trim does")
        store.selectWorker("w2")
        expect(store.revision == revision + 1, "a tab that leaves the same (no) lines on screen changes nothing")
        store.selectWorker(nil)

        let hidden = store.revision
        _ = store.receive(WorkerFeedPayload(entries: [entry(10, "w1", "say", "hidden arrival")]), for: request)
        expect(store.revision == hidden, "an arrival the filter hides changes nothing on screen")

        _ = store.receive(WorkerFeedPayload(entries: [entry(20, "w1", "status", "working")]), for: request)
        expect(store.lastUpdateAppended && store.lines.count == 1, "an arrival it shows is an append")
    }

    /// The panel draws its empty icon when `isKnownEmpty`: a feed that has lines but none the filter shows is empty to the
    /// reader, while a first read still on its way is blank, filter or not. The tab row stays under the icon either way.
    private static func filterHidingEveryLineLeavesNothingToList() {
        let (store, request) = openStore(entries: [entry(0, "w1", "say", "one")])
        expect(!store.isKnownEmpty, "a feed showing a line is not empty")
        store.toggleAction(at: row(.status))
        expect(store.lines.isEmpty && store.isKnownEmpty, "a filter that hides every line leaves nothing to list")
        expect(store.filter.actionSummary != nil, "and the chip that did it stays, so its x can clear it")
        _ = store.receive(WorkerFeedPayload(entries: [entry(10, "w1", "say", "also hidden")]), for: request)
        expect(store.isKnownEmpty, "a hidden arrival changes nothing")
        store.clearActions()
        expect(!store.isKnownEmpty && store.lines.count == 2, "clearing the filter shows the lines again")

        store.selectWorker("w2")
        expect(store.lines.isEmpty && store.isKnownEmpty, "a tab whose worker has no lines leaves nothing to list")
        expect(store.workers.count == 2 && store.filter.workerID == "w2", "and the tabs stay, with the selection on it")
        store.selectWorker("w1")
        expect(!store.isKnownEmpty && store.lines.count == 2, "another tab shows its lines")

        let partial = makeStore()
        let partialRequest = partial.sync(selectedSessionID: "m", sessions: tracker(workers: 2), isVisible: true)
        _ = partial.receive(WorkerFeedPayload(entries: [entry(0, "w1", "say", "one")], hasMore: ["w1": true]), for: partialRequest!)
        partial.toggleAction(at: row(.status))
        expect(partial.lines.isEmpty && partial.isKnownEmpty, "a feed with lines the filter hides is empty to the reader even with more to read")

        let pending = makeStore()
        _ = pending.sync(selectedSessionID: "m", sessions: tracker(workers: 2), isVisible: true)
        pending.toggleAction(at: row(.status))
        expect(narrows(pending.filter) && !pending.isKnownEmpty, "a filter set while the first read is pending is blank, not empty")
        let pendingTab = makeStore()
        _ = pendingTab.sync(selectedSessionID: "m", sessions: tracker(workers: 2), isVisible: true)
        pendingTab.selectWorker("w2")
        expect(narrows(pendingTab.filter) && !pendingTab.isKnownEmpty, "so is a tab picked while the first read is pending")
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

    /// Whether the filter narrows the log at all: an Action ticked or a worker tab selected.
    private static func narrows(_ filter: WorkerLogFilter) -> Bool {
        !filter.actions.isEmpty || filter.workerID != nil
    }

    /// The row index of an Action box.
    private static func row(_ action: WorkerLogAction) -> Int {
        WorkerLogAction.allCases.firstIndex(of: action) ?? -1
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
