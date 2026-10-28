import Foundation

/// The Worker Log filter's Action boxes, in the order the dropdown lists them and the chip names them: alphabetical.
/// Each groups the feed entries it names.
public enum WorkerLogAction: CaseIterable, Hashable, Sendable {
    /// Tool calls.
    case cast
    /// The item tags: reports and instructions.
    case item
    /// A worker's free text.
    case message
    case status
    /// Sub-agents appearing and leaving: summon and dismiss lines.
    case summon

    public var title: String {
        switch self {
        case .cast: "Cast"
        case .item: "Item"
        case .message: "Message"
        case .status: "Status"
        case .summon: "Summon"
        }
    }
}

extension WorkerChatRecord.Kind {
    var logAction: WorkerLogAction {
        switch self {
        case .action: .cast
        case .status: .status
        case .summon, .dismiss: .summon
        case .say, .message: .message
        case .report, .instructions: .item
        }
    }
}

/// One of the attached master's workers, as the tab row lists it, in the order the tracker shows them.
public struct WorkerLogWorker: Equatable, Identifiable, Sendable {
    public let id: String
    /// The name the log's lines draw.
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// What the Worker Log shows. No Action ticked lets every action through; a tick narrows the log to the actions it
/// names. That holds when every box is ticked too: it is an ordinary selection, and only the chip's x clears it. A line
/// needs to match one ticked Action, and the selected worker tab if there is one. The Action ticks are app-wide, shared
/// by every master; the tab row picks one of the attached master's workers or, with `workerID` nil, All, and a worker
/// that spawns later shows under All and under its own tab. `WorkerChatStore` keeps the ticks across masters and each
/// master's tab.
public struct WorkerLogFilter: Equatable, Sendable {
    public private(set) var actions: Set<WorkerLogAction> = []
    /// The selected worker tab; nil is the All tab.
    public private(set) var workerID: String?

    public init() {}

    public func allows(_ line: WorkerChatLine) -> Bool {
        let allowsAction = actions.isEmpty || actions.contains(line.action)
        let allowsWorker = workerID == nil || workerID == line.workerID
        return allowsAction && allowsWorker
    }

    /// The Action chip's value: the names of the ticked actions, comma-separated in the dropdown's order. Nil with none
    /// ticked.
    public var actionSummary: String? {
        guard !actions.isEmpty else {
            return nil
        }
        return WorkerLogAction.allCases.filter(actions.contains).map(\.title).joined(separator: ", ")
    }

    public mutating func toggle(_ action: WorkerLogAction) {
        actions.formSymmetricDifference([action])
    }

    public mutating func clearActions() {
        actions = []
    }

    /// Selects a worker's tab, or All with nil.
    public mutating func selectWorker(_ id: String?) {
        workerID = id
    }

    /// Whether the tab row shows for these workers: from two on. All plus one worker's tab adds nothing.
    public static func showsTabs(for workers: [WorkerLogWorker]) -> Bool {
        workers.count > 1
    }

    /// Falls back to All when the selected worker is gone, or when there are too few workers to show a tab row, so the
    /// log never stays narrowed to a worker with no tab to say so.
    public mutating func reconcile(with workers: [WorkerLogWorker]) {
        guard let workerID else {
            return
        }
        guard Self.showsTabs(for: workers), workers.contains(where: { $0.id == workerID }) else {
            self.workerID = nil
            return
        }
    }

    /// The selected tab's position in the tab row: All, then one per worker.
    public func tabIndex(in workers: [WorkerLogWorker]) -> Int {
        guard let workerID, let index = workers.firstIndex(where: { $0.id == workerID }) else {
            return 0
        }
        return index + 1
    }

    /// Moves the selection by `delta` tabs, wrapping at both ends as the Settings tabs do.
    public mutating func moveTab(_ delta: Int, in workers: [WorkerLogWorker]) {
        guard Self.showsTabs(for: workers) else {
            return
        }
        let count = workers.count + 1
        let next = (tabIndex(in: workers) + delta % count + count) % count
        workerID = next == 0 ? nil : workers[next - 1].id
    }
}

/// The filter dropdown: whether it is open and which row the keyboard cursor is on.
public struct WorkerLogMenu: Equatable, Sendable {
    public private(set) var isOpen = false
    public private(set) var cursor = 0

    public init() {}

    /// Opens with the cursor on the first row.
    public mutating func toggleOpen() {
        isOpen.toggle()
        cursor = 0
    }

    public mutating func close() {
        isOpen = false
    }

    public mutating func moveCursor(by delta: Int, rowCount: Int) {
        guard rowCount > 0 else {
            return
        }
        cursor = min(max(cursor + delta, 0), rowCount - 1)
    }

    public mutating func setCursor(_ index: Int, rowCount: Int) {
        guard (0..<rowCount).contains(index) else {
            return
        }
        cursor = index
    }
}

/// What a key does to the Worker Log filter and its tabs. Only the exact chords in `Keymap` match, so a ⌘, ⌃, ⌥ or ⇧ press passes through.
public enum WorkerLogFilterKey: Equatable, Sendable {
    case toggleMenu
    case close
    case moveUp
    case moveDown
    case toggleRow
    case previousTab
    case nextTab

    /// Only `toggleMenu` and the tab keys mean anything while the dropdown is closed.
    public static func resolve(_ press: Keymap.KeyPress, menuIsOpen: Bool) -> WorkerLogFilterKey? {
        if Keymap.matches(press, .toggleFilterMenu) {
            return .toggleMenu
        }
        if Keymap.matches(press, .previousTab) {
            return .previousTab
        }
        if Keymap.matches(press, .nextTab) {
            return .nextTab
        }
        guard menuIsOpen else {
            return nil
        }
        if Keymap.matches(press, .cancel) {
            return .close
        }
        if Keymap.matches(press, .moveUp) {
            return .moveUp
        }
        if Keymap.matches(press, .moveDown) {
            return .moveDown
        }
        if Keymap.matches(press, .toggleRow) {
            return .toggleRow
        }
        return nil
    }
}
