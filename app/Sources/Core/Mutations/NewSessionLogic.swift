import Foundation

public enum NewSessionRole: Equatable {
    case standalone
    case master

    public var isMaster: Bool {
        self == .master
    }
}

public enum NewSessionField: CaseIterable, Equatable, Hashable {
    case path
    case title
    case agent
    case role
    case color
    case prompt

    public var isSelect: Bool {
        self == .agent || self == .color || self == .role
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

public enum NewSessionPromptReturnAction: Equatable {
    case create
    case newline

    public static func forReturn(shiftHeld: Bool) -> NewSessionPromptReturnAction {
        shiftHeld ? .newline : .create
    }
}

public struct NewSessionSubmitPayload: Equatable {
    public let role: NewSessionRole
    public let path: String
    public let title: String?
    public let agent: String
    public let color: String
    public let prompt: String?
}

public struct NewSessionFormModel: Equatable {
    public static let defaultAgents = ["claude", "codex", "opencode", "pi"]
    public static let noColor = ""
    public static let noColorLabel = "none"
    public static let defaultColors = [
        noColor,
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
    public private(set) var selectedAgentIndex: Int
    public private(set) var selectedColorIndex: Int

    public init(
        role: NewSessionRole,
        initialPath: String,
        initialTitle: String = "",
        initialPrompt: String = "",
        initialFocus: NewSessionField = .path,
        initialColor: String = NewSessionFormModel.noColor,
        agents: [String] = NewSessionFormModel.defaultAgents,
        colors: [String] = NewSessionFormModel.defaultColors
    ) {
        self.role = role
        focusedField = initialFocus
        path = initialPath
        title = initialTitle
        prompt = initialPrompt
        submitting = false
        errorMessage = nil
        self.agents = agents.isEmpty ? NewSessionFormModel.defaultAgents : agents
        self.colors = colors.isEmpty ? NewSessionFormModel.defaultColors : colors
        selectedAgentIndex = 0
        selectedColorIndex = Self.colorIndex(for: initialColor, in: self.colors)
    }

    public var selectedAgent: String {
        value(at: selectedAgentIndex, in: agents) ?? NewSessionFormModel.defaultAgents[0]
    }

    public var selectedColor: String {
        clean(value(at: selectedColorIndex, in: colors)) ?? Self.noColor
    }

    public var selectedColorLabel: String {
        selectedColor.isEmpty ? Self.noColorLabel : selectedColor
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
            prompt: clean(prompt)
        )
    }

    public mutating func setSubmitting(_ submitting: Bool) {
        self.submitting = submitting
    }

    public mutating func setError(_ message: String?) {
        errorMessage = clean(message)
    }

    /// Resolves the color to persist from an edit sheet, distinguishing "the
    /// color control was never touched this session" from "the user actively
    /// navigated to the no-color entry." A real color selection always wins.
    /// Otherwise, an untouched no-color selection preserves whatever raw value
    /// the sheet started with (so a plain rename never changes color), while an
    /// actively-selected no-color entry becomes the literal "none".
    public static func resolvedColorForSave(
        selectedColor: String,
        selectedColorIndex: Int,
        initialColorIndex: Int,
        initialColor: String
    ) -> String {
        guard selectedColor.isEmpty else {
            return selectedColor
        }
        guard selectedColorIndex != initialColorIndex else {
            return initialColor
        }
        return "none"
    }

    private mutating func moveFocus(_ delta: Int) {
        let fields = NewSessionField.allCases
        guard let index = fields.firstIndex(of: focusedField) else {
            focusedField = .path
            return
        }
        focusedField = fields[wrapped(index + delta, count: fields.count)]
    }

    private mutating func cycleSelection(_ delta: Int) {
        switch focusedField {
        case .agent:
            selectedAgentIndex = wrapped(selectedAgentIndex + delta, count: agents.count)
        case .color:
            selectedColorIndex = wrapped(selectedColorIndex + delta, count: colors.count)
        case .role:
            let roles: [NewSessionRole] = [.standalone, .master]
            let index = roles.firstIndex(of: role) ?? 0
            role = roles[wrapped(index + delta, count: roles.count)]
        case .path, .title, .prompt:
            break
        }
    }

    private static func colorIndex(for color: String, in colors: [String]) -> Int {
        if let index = colors.firstIndex(where: { clean($0) == clean(color) }) {
            return index
        }
        return colors.firstIndex { clean($0) == nil } ?? colors.firstIndex(of: "blue") ?? 0
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
