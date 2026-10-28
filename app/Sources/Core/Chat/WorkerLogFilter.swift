import Foundation

/// The Worker Log filter's Action boxes, in the order the dropdown lists them. Each groups the feed entries it names.
public enum WorkerLogAction: CaseIterable, Hashable, Sendable {
    /// Tool calls.
    case cast
    case status
    /// Sub-agents appearing and leaving: summon and dismiss lines.
    case summon
    /// A worker's free text.
    case message
    /// The item tags: reports and instructions.
    case item

    public var title: String {
        switch self {
        case .cast: "Cast"
        case .status: "Status"
        case .summon: "Summon"
        case .message: "Message"
        case .item: "Item"
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

/// What the Worker Log shows for one master. No Action ticked lets every action through; a tick narrows the log to the
/// actions it names. That holds when every box is ticked too: it is an ordinary selection, and only the chip's x clears
/// it. A line needs to match one ticked Action, and the selected worker tab if there is one. The tab row picks one
/// worker or, with `workerID` nil, All; a worker that spawns later shows under All and under its own tab.
public struct WorkerLogFilter: Equatable, Sendable {
    public private(set) var actions: Set<WorkerLogAction> = []
    /// The selected worker tab; nil is the All tab.
    public private(set) var workerID: String?

    public init() {}

    public var isActive: Bool {
        !actions.isEmpty || workerID != nil
    }

    public func allows(_ line: WorkerChatLine) -> Bool {
        let allowsAction = actions.isEmpty || actions.contains(line.action)
        let allowsWorker = workerID == nil || workerID == line.workerID
        return allowsAction && allowsWorker
    }

    /// The Action chip's value: one action's name, or the number of actions ticked. Nil with none ticked.
    public var actionSummary: String? {
        if let only = actions.first, actions.count == 1 {
            return only.title
        }
        return actions.isEmpty ? nil : String(actions.count)
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

    /// Falls back to All when the selected worker is gone.
    public mutating func reconcile(with workers: [WorkerLogWorker]) {
        guard let workerID, !workers.contains(where: { $0.id == workerID }) else {
            return
        }
        self.workerID = nil
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
        guard !workers.isEmpty else {
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

/// What a key does to the Worker Log filter and its tabs. The caller screens out the ⌘, ⌃, ⌥ and ⇧ chords.
public enum WorkerLogFilterKey: Equatable, Sendable {
    case toggleMenu
    case close
    case moveUp
    case moveDown
    case toggleRow
    case previousTab
    case nextTab

    /// Only `toggleMenu` and the tab keys mean anything while the dropdown is closed.
    public static func resolve(keyCode: UInt16, character: String?, menuIsOpen: Bool) -> WorkerLogFilterKey? {
        if Keymap.WorkerLog.toggleMenu.matches(character) {
            return .toggleMenu
        }
        if Keymap.WorkerLog.previousTab.matches(character) {
            return .previousTab
        }
        if Keymap.WorkerLog.nextTab.matches(character) {
            return .nextTab
        }
        guard menuIsOpen else {
            return nil
        }
        if Keymap.WorkerLog.close.matches(keyCode) {
            return .close
        }
        if Keymap.WorkerLog.moveUpKeyCodes.matches(keyCode) || Keymap.WorkerLog.moveUpCharacters.matches(character) {
            return .moveUp
        }
        if Keymap.WorkerLog.moveDownKeyCodes.matches(keyCode) || Keymap.WorkerLog.moveDownCharacters.matches(character) {
            return .moveDown
        }
        if Keymap.WorkerLog.toggleRowKeyCodes.matches(keyCode) || Keymap.WorkerLog.toggleRowCharacters.matches(character) {
            return .toggleRow
        }
        return nil
    }
}
