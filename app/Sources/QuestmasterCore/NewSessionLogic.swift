import Foundation

public enum NewSessionRole: Equatable {
    case standalone
    case master

    public var isMaster: Bool {
        self == .master
    }

    public var headerTitle: String {
        switch self {
        case .standalone:
            return "New session"
        case .master:
            return "New master session"
        }
    }
}

public enum NewSessionField: CaseIterable, Equatable {
    case path
    case title
    case agent
    case color
    case quest
    case prompt

    public var isSelect: Bool {
        self == .agent || self == .color || self == .quest
    }
}

public enum NewSessionFormKey: Equatable {
    case controlJ
    case controlK
    case left
    case right
    case enter
    case controlS
}

public struct NewSessionQuestOption: Equatable {
    public let id: String
    public let title: String

    public init(id: String, title: String = "") {
        self.id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var label: String {
        title.isEmpty ? id : "\(id) - \(title)"
    }
}

public struct NewSessionSubmitPayload: Equatable {
    public let role: NewSessionRole
    public let path: String
    public let title: String?
    public let agent: String
    public let color: String
    public let questID: String?
    public let prompt: String?
}

public struct NewSessionFormModel: Equatable {
    public static let defaultAgents = ["claude", "codex", "pi", "omp"]
    public static let defaultColors = [
        "blue", "green", "yellow", "magenta", "cyan", "red", "orange",
        "gold", "lime", "teal", "sky", "indigo", "violet", "pink",
    ]

    public private(set) var role: NewSessionRole
    public var focusedField: NewSessionField
    public var path: String
    public var title: String
    public var prompt: String
    public var submitting: Bool
    public var errorMessage: String?

    public private(set) var agents: [String]
    public private(set) var colors: [String]
    public private(set) var quests: [NewSessionQuestOption]
    public private(set) var selectedAgentIndex: Int
    public private(set) var selectedColorIndex: Int
    public private(set) var selectedQuestIndex: Int

    public init(
        role: NewSessionRole,
        initialPath: String,
        agents: [String] = NewSessionFormModel.defaultAgents,
        colors: [String] = NewSessionFormModel.defaultColors,
        quests: [NewSessionQuestOption] = []
    ) {
        self.role = role
        focusedField = .path
        path = initialPath
        title = ""
        prompt = ""
        submitting = false
        errorMessage = nil
        self.agents = agents.isEmpty ? NewSessionFormModel.defaultAgents : agents
        self.colors = colors.isEmpty ? NewSessionFormModel.defaultColors : colors
        self.quests = quests.filter { !$0.id.isEmpty }
        selectedAgentIndex = 0
        selectedColorIndex = max(0, self.colors.firstIndex(of: "blue") ?? 0)
        selectedQuestIndex = 0
    }

    public var headerTitle: String {
        role.headerTitle
    }

    public var selectedAgent: String {
        value(at: selectedAgentIndex, in: agents) ?? NewSessionFormModel.defaultAgents[0]
    }

    public var selectedColor: String {
        value(at: selectedColorIndex, in: colors) ?? "blue"
    }

    public var selectedQuestID: String? {
        guard selectedQuestIndex > 0 else {
            return nil
        }
        return value(at: selectedQuestIndex - 1, in: quests)?.id
    }

    public var selectedQuestLabel: String {
        guard selectedQuestIndex > 0 else {
            return "none"
        }
        return value(at: selectedQuestIndex - 1, in: quests)?.label ?? "none"
    }

    public mutating func setRole(_ role: NewSessionRole) {
        self.role = role
    }

    public mutating func handle(_ key: NewSessionFormKey) {
        guard !submitting else {
            return
        }
        switch key {
        case .controlJ:
            moveFocus(1)
        case .controlK:
            moveFocus(-1)
        case .left:
            cycleSelection(-1)
        case .right:
            cycleSelection(1)
        case .enter, .controlS:
            break
        }
    }

    public var isSelectFocused: Bool {
        focusedField.isSelect
    }

    @discardableResult
    public mutating func handleSelectShortcut(_ key: String?) -> Bool {
        guard isSelectFocused else {
            return false
        }
        if Keymap.NewSession.selectLeftCharacter.matches(key) {
            handle(.left)
            return true
        }
        if Keymap.NewSession.selectRightCharacter.matches(key) {
            handle(.right)
            return true
        }
        return false
    }

    public func creationRequested(by key: NewSessionFormKey) -> Bool {
        switch key {
        case .enter:
            return focusedField != .prompt
        case .controlS:
            return focusedField == .prompt
        default:
            return false
        }
    }

    public mutating func submitPayload() -> NewSessionSubmitPayload? {
        let cleanPath = clean(path) ?? ""
        guard !cleanPath.isEmpty else {
            errorMessage = "path is required"
            return nil
        }
        errorMessage = nil
        return NewSessionSubmitPayload(
            role: role,
            path: cleanPath,
            title: clean(title),
            agent: selectedAgent,
            color: selectedColor,
            questID: selectedQuestID,
            prompt: clean(prompt)
        )
    }

    public mutating func setSubmitting(_ submitting: Bool) {
        self.submitting = submitting
    }

    public mutating func setError(_ message: String?) {
        errorMessage = clean(message)
    }

    public mutating func setQuests(_ quests: [NewSessionQuestOption]) {
        self.quests = quests.filter { !$0.id.isEmpty }
        if selectedQuestIndex > self.quests.count {
            selectedQuestIndex = 0
        }
    }

    private mutating func moveFocus(_ delta: Int) {
        let fields = NewSessionField.allCases
        guard let index = fields.firstIndex(of: focusedField) else {
            focusedField = .path
            return
        }
        focusedField = fields[min(max(index + delta, fields.startIndex), fields.index(before: fields.endIndex))]
    }

    private mutating func cycleSelection(_ delta: Int) {
        switch focusedField {
        case .agent:
            selectedAgentIndex = wrapped(selectedAgentIndex + delta, count: agents.count)
        case .color:
            selectedColorIndex = wrapped(selectedColorIndex + delta, count: colors.count)
        case .quest:
            selectedQuestIndex = wrapped(selectedQuestIndex + delta, count: quests.count + 1)
        case .path, .title, .prompt:
            break
        }
    }
}

private func clean(_ value: String?) -> String? {
    guard let value else {
        return nil
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func value<T>(at index: Int, in values: [T]) -> T? {
    guard values.indices.contains(index) else {
        return nil
    }
    return values[index]
}

private func wrapped(_ index: Int, count: Int) -> Int {
    guard count > 0 else {
        return 0
    }
    if index < 0 {
        return count - 1
    }
    if index >= count {
        return 0
    }
    return index
}
