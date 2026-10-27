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

/// The filter's two sections.
public enum WorkerLogSection: Hashable, Sendable {
    case action
    case worker
}

/// One of the attached master's workers, as the filter lists it, in the order the tracker shows them.
public struct WorkerLogWorker: Equatable, Identifiable, Sendable {
    public let id: String
    /// The name the log's lines draw.
    public let name: String
    public let agent: String

    public init(id: String, name: String, agent: String) {
        self.id = id
        self.name = name
        self.agent = agent
    }
}

/// A selection chip: its section and what it shows.
public struct WorkerLogChip: Equatable, Identifiable, Sendable {
    public struct AgentCount: Equatable, Sendable {
        public let agent: String
        public let count: Int

        public init(agent: String, count: Int) {
            self.agent = agent
            self.count = count
        }
    }

    public enum Value: Equatable, Sendable {
        /// One action's name, or the number of actions selected.
        case text(String)
        case worker(name: String, agent: String)
        /// Several workers: how many of each agent, in the order the tracker shows the agents.
        case agentCounts([AgentCount])
    }

    public let section: WorkerLogSection
    public let value: Value

    public init(section: WorkerLogSection, value: Value) {
        self.section = section
        self.value = value
    }

    public var id: WorkerLogSection { section }

    public var title: String {
        switch section {
        case .action: "Action"
        case .worker: "Worker"
        }
    }
}

/// A row of the filter dropdown.
public enum WorkerLogMenuRow: Equatable, Identifiable, Sendable {
    case action(WorkerLogAction)
    case worker(WorkerLogWorker)

    public var id: String {
        switch self {
        case .action(let action): "action:\(action.title)"
        case .worker(let worker): "worker:\(worker.id)"
        }
    }

    public var section: WorkerLogSection {
        switch self {
        case .action: .action
        case .worker: .worker
        }
    }

    /// The Action rows, then one row per worker.
    public static func rows(workers: [WorkerLogWorker]) -> [WorkerLogMenuRow] {
        WorkerLogAction.allCases.map(WorkerLogMenuRow.action) + workers.map(WorkerLogMenuRow.worker)
    }
}

/// What the Worker Log shows for one master. A section with nothing selected lets everything through; a selection narrows
/// the log to what it names, so a worker that appears later stays hidden until it is selected or the section is cleared.
/// That holds when every box is ticked too: it is an ordinary selection, and only its chip's x clears it. Within a
/// section a line needs to match one selection, and across the two sections both.
public struct WorkerLogFilter: Equatable, Sendable {
    public private(set) var actions: Set<WorkerLogAction> = []
    public private(set) var workerIDs: Set<String> = []

    public init() {}

    public var isActive: Bool {
        !actions.isEmpty || !workerIDs.isEmpty
    }

    public func allows(_ line: WorkerChatLine) -> Bool {
        let allowsAction = actions.isEmpty || actions.contains(line.action)
        let allowsWorker = workerIDs.isEmpty || workerIDs.contains(line.workerID)
        return allowsAction && allowsWorker
    }

    public func isChecked(_ row: WorkerLogMenuRow) -> Bool {
        switch row {
        case .action(let action): actions.contains(action)
        case .worker(let worker): workerIDs.contains(worker.id)
        }
    }

    public mutating func toggle(_ action: WorkerLogAction) {
        actions.formSymmetricDifference([action])
    }

    public mutating func toggle(_ worker: WorkerLogWorker) {
        workerIDs.formSymmetricDifference([worker.id])
    }

    public mutating func clear(_ section: WorkerLogSection) {
        switch section {
        case .action: actions = []
        case .worker: workerIDs = []
        }
    }

    /// Forgets selected workers that are gone. If none are left, the section is cleared.
    public mutating func reconcile(with workers: [WorkerLogWorker]) {
        workerIDs.formIntersection(workers.map(\.id))
    }

    /// One chip per section with a selection: the Action chip first.
    public func chips(workers: [WorkerLogWorker]) -> [WorkerLogChip] {
        var chips: [WorkerLogChip] = []
        if let only = actions.first, actions.count == 1 {
            chips.append(WorkerLogChip(section: .action, value: .text(only.title)))
        } else if !actions.isEmpty {
            chips.append(WorkerLogChip(section: .action, value: .text(String(actions.count))))
        }
        let selected = workers.filter { workerIDs.contains($0.id) }
        if let only = selected.first, selected.count == 1 {
            chips.append(WorkerLogChip(section: .worker, value: .worker(name: only.name, agent: only.agent)))
        } else if !selected.isEmpty {
            chips.append(WorkerLogChip(section: .worker, value: .agentCounts(Self.agentCounts(of: selected))))
        }
        return chips
    }

    private static func agentCounts(of workers: [WorkerLogWorker]) -> [WorkerLogChip.AgentCount] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for worker in workers {
            if counts[worker.agent] == nil {
                order.append(worker.agent)
            }
            counts[worker.agent, default: 0] += 1
        }
        return order.map { WorkerLogChip.AgentCount(agent: $0, count: counts[$0] ?? 0) }
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

    /// Keeps the cursor on a row after the workers changed under an open dropdown.
    public mutating func clampCursor(rowCount: Int) {
        cursor = min(cursor, max(rowCount - 1, 0))
    }
}

/// What a key does to the Worker Log filter. The caller screens out the ⌘, ⌃, ⌥ and ⇧ chords.
public enum WorkerLogFilterKey: Equatable, Sendable {
    case toggleMenu
    case close
    case moveUp
    case moveDown
    case toggleRow

    /// Only `toggleMenu` means anything while the dropdown is closed.
    public static func resolve(keyCode: UInt16, character: String?, menuIsOpen: Bool) -> WorkerLogFilterKey? {
        if Keymap.WorkerLog.toggleMenu.matches(character) {
            return .toggleMenu
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
