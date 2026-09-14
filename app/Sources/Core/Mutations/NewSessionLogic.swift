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
    case role
    case agent
    case model
    case color
    case prompt

    public var isSelect: Bool {
        self == .agent || self == .color || self == .role || self == .model
    }
}

/// One entry in the model select.
///
/// The options are pushed in from the serve `models` topic rather than
/// declared here: the app must never carry a model list, or a newly released
/// model would need an app release. There is no synthetic "default" entry —
/// every option is a real, concrete id; "nothing selected" is a fact about
/// the form's selection state (see `NewSessionFormModel.selectedModelIndex`),
/// not a member of this list.
public struct SessionModelOption: Equatable {
    public let id: String
    public let label: String
    public let note: String

    public init(id: String, label: String, note: String = "") {
        self.id = id
        self.label = label
        self.note = note
    }
}

/// One entry in the reasoning-effort select.
///
/// Levels come from the serve `reasoning_efforts` topic rather than being
/// declared here, same as `SessionModelOption` — the valid set differs per
/// harness and, for Codex/OpenCode, per model.
public struct SessionReasoningEffortOption: Equatable {
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
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
    /// Empty means "no override for this launch": whatever Settings has
    /// configured for this agent+role applies, or nothing if Settings has
    /// nothing configured either.
    public let model: String
    /// Empty means "no override for this launch": whatever Settings has
    /// configured for this agent+role applies, or nothing if Settings has
    /// nothing configured either.
    public let reasoningEffort: String
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
    public private(set) var modelOptions: [SessionModelOption]
    public private(set) var effortOptions: [SessionReasoningEffortOption]
    public private(set) var selectedAgentIndex: Int
    public private(set) var selectedColorIndex: Int
    /// Nil means nothing is selected — no override for this launch, whatever
    /// Settings has configured for this agent+role applies.
    public private(set) var selectedModelIndex: Int?
    public private(set) var selectedEffortIndex: Int?
    /// False until `setModelOptions`/`setEffortOptions` first resolves this
    /// agent+role's real list — first resolve pre-selects Settings' current
    /// default (if any); a later re-resolve (agent/role change) instead
    /// preserves whatever is currently selected.
    private var hasResolvedModelOptions = false
    private var hasResolvedEffortOptions = false

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
        modelOptions = []
        effortOptions = []
        selectedAgentIndex = 0
        selectedColorIndex = Self.colorIndex(for: initialColor, in: self.colors)
        selectedModelIndex = nil
        selectedEffortIndex = nil
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

    /// The selected model id, empty when nothing is selected.
    public var selectedModel: String {
        selectedModelOption?.id ?? ""
    }

    public var selectedModelOption: SessionModelOption? {
        selectedModelIndex.flatMap { value(at: $0, in: modelOptions) }
    }

    /// The selected reasoning-effort level, empty when nothing is selected.
    public var selectedReasoningEffort: String {
        selectedEffortOption?.id ?? ""
    }

    public var selectedEffortOption: SessionReasoningEffortOption? {
        selectedEffortIndex.flatMap { value(at: $0, in: effortOptions) }
    }

    public mutating func setRole(_ role: NewSessionRole) {
        guard self.role != role else {
            return
        }
        self.role = role
        // The role decides which default model (and reasoning effort) the
        // harness applies, so the resolved lists no longer describe this form.
        resetModelOptions()
        resetEffortOptions()
    }

    /// Replaces the model list with what the backend resolved for the current
    /// agent and role. On the very first resolve for this agent+role, the
    /// selection seeds onto `defaultModel` (whatever Settings currently has
    /// configured, if anything) directly. A later re-resolve (the effort list
    /// refetching after the user changes the model) instead preserves
    /// whatever is currently selected, so an in-progress choice survives.
    public mutating func setModelOptions(_ models: [SessionModelOption], defaultModel: String = "") {
        let firstResolve = !hasResolvedModelOptions
        let previousID = selectedModelOption?.id
        // A whitespace-only id would otherwise render as "selected" while
        // MutationRequests.start's trimming silently treats it as unset at
        // submit time — drop it here so the picker never shows a selection
        // that launches without an override anyway.
        modelOptions = models.filter { !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if firstResolve {
            selectedModelIndex = defaultModel.isEmpty ? nil : modelOptions.firstIndex(where: { $0.id == defaultModel })
        } else {
            selectedModelIndex = previousID.flatMap { id in modelOptions.firstIndex(where: { $0.id == id }) }
        }
        hasResolvedModelOptions = true
    }

    /// Drops back to an empty, unresolved list, for when the resolved list
    /// stops applying (the agent or role changed) or a fetch failed — the
    /// next `setModelOptions` call is then treated as a fresh first resolve.
    public mutating func resetModelOptions() {
        modelOptions = []
        selectedModelIndex = nil
        hasResolvedModelOptions = false
    }

    /// Replaces the reasoning-effort list with what the backend resolved for
    /// the current agent, role and model. Mirrors `setModelOptions`'s
    /// first-resolve seeding.
    public mutating func setEffortOptions(_ levels: [String], defaultLevel: String = "") {
        let firstResolve = !hasResolvedEffortOptions
        let previousID = selectedEffortOption?.id
        effortOptions = levels.compactMap { level in
            let trimmed = level.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : SessionReasoningEffortOption(id: trimmed, label: trimmed)
        }
        if firstResolve {
            selectedEffortIndex = defaultLevel.isEmpty ? nil : effortOptions.firstIndex(where: { $0.id == defaultLevel })
        } else {
            selectedEffortIndex = previousID.flatMap { id in effortOptions.firstIndex(where: { $0.id == id }) }
        }
        hasResolvedEffortOptions = true
    }

    /// Drops back to an empty, unresolved list, for when the resolved list
    /// stops applying (the agent, role or model changed) or a fetch failed.
    public mutating func resetEffortOptions() {
        effortOptions = []
        selectedEffortIndex = nil
        hasResolvedEffortOptions = false
    }

    /// Cycles the reasoning-effort selection independent of focus — bound to
    /// `e` while the Model field is focused, since Effort has no row of its
    /// own (its current value is a sub-text of the Model row instead).
    public mutating func cycleReasoningEffort() {
        guard !submitting else {
            return
        }
        selectedEffortIndex = cycleOptionalIndex(selectedEffortIndex, delta: 1, count: effortOptions.count)
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
            model: selectedModel,
            reasoningEffort: selectedReasoningEffort,
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
            let previousAgent = selectedAgent
            selectedAgentIndex = wrapped(selectedAgentIndex + delta, count: agents.count)
            // Model ids are harness-specific, so another agent's list never
            // carries over — the sheet resolves a fresh one. Only reset when
            // the agent actually changed (mirrors setRole), so cycling a
            // single-agent list doesn't needlessly drop an already-resolved
            // list.
            if selectedAgent != previousAgent {
                resetModelOptions()
                resetEffortOptions()
            }
        case .model:
            selectedModelIndex = cycleOptionalIndex(selectedModelIndex, delta: delta, count: modelOptions.count)
        case .color:
            selectedColorIndex = wrapped(selectedColorIndex + delta, count: colors.count)
        case .role:
            let roles: [NewSessionRole] = [.standalone, .master]
            let index = roles.firstIndex(of: role) ?? 0
            setRole(roles[wrapped(index + delta, count: roles.count)])
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

/// Cycles among `count` real options plus a virtual "nothing selected" slot,
/// wrapping. The virtual slot sits last, after every real option, and always
/// maps to `nil` — New Session never gates it off (unlike Settings' own
/// `RoleDefaultRow`), since deferring to whatever Settings currently has
/// configured (or nothing) is always a legitimate choice for a one-shot
/// launch.
private func cycleOptionalIndex(_ current: Int?, delta: Int, count: Int) -> Int? {
    let currentSlot = current ?? count
    let next = wrapped(currentSlot + delta, count: count + 1)
    return next < count ? next : nil
}
