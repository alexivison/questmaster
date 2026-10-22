import Foundation

public enum NewSessionField: CaseIterable, Equatable, Hashable {
    case path
    case title
    case agent
    case model
    /// The effort segment at the model field's right end.
    case effort
    /// Edit Session's colour select. New Session has no colour field: a new session takes the default.
    case color
    case prompt

    public var isSelect: Bool {
        self == .agent || self == .effort || self == .color
    }

    /// New Session's fields, top to bottom: the order ⌃j / ⌃k and Tab move through.
    public static let formOrder: [NewSessionField] = [.path, .title, .agent, .model, .effort, .prompt]
}

/// One model suggestion for the model field.
///
/// The options are pushed in from the serve `models` topic rather than
/// declared here: the app must never carry a model list, or a newly released
/// model would need an app release. They only suggest: the field takes any
/// text, and model ids are never validated.
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

/// The keys that cycle the reasoning effort: plain e where an e can't be typed (the effort segment and
/// the agent tabs), ⌥e while typing in the model field, whose ids are full of e's.
public enum NewSessionEffortKey {
    public static func cycles(characters: String?, keyCode: UInt16, option: Bool, field: NewSessionField) -> Bool {
        switch field {
        case .effort, .agent:
            return !option && Keymap.NewSession.cycleReasoningEffort.matchesExactly(characters)
        case .model:
            return option && Keymap.NewSession.cycleReasoningEffortInModel.matches(keyCode)
        case .path, .title, .color, .prompt:
            return false
        }
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
    public let path: String
    public let title: String?
    public let agent: String
    /// Empty means "no override for this launch": whatever Settings has
    /// configured for this agent's master role applies, or nothing if Settings has
    /// nothing configured either.
    public let model: String
    /// Empty means "no override for this launch": whatever Settings has
    /// configured for this agent's master role applies, or nothing if Settings has
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
    /// The model field's text: any id, passed to the harness as typed. Empty means no override for this
    /// launch: whatever Settings has configured for this agent's master role applies.
    public private(set) var modelText = ""
    /// The highlighted row of `modelSuggestions`.
    public private(set) var highlightedModelIndex = 0
    /// Esc, or accepting a suggestion, puts the model dropdown away until the next keystroke.
    public private(set) var modelSuggestionsDismissed = false
    public private(set) var selectedEffortIndex: Int?
    /// Until the user types in the model field, each resolve fills it with Settings' default for the role.
    private var modelTextEdited = false
    /// False until `setEffortOptions` first resolves this agent's master-role
    /// list — first resolve pre-selects Settings' current default (if any); a
    /// later re-resolve (a model change) instead preserves whatever is
    /// currently selected.
    private var hasResolvedEffortOptions = false

    /// How many model suggestions the dropdown lists at most.
    public static let maxModelSuggestions = 5
    /// The effort segment's text when nothing is chosen, or the model reports no levels: the harness decides.
    public static let defaultEffortLabel = "default"

    public init(
        initialPath: String,
        initialTitle: String = "",
        initialPrompt: String = "",
        initialFocus: NewSessionField = .path,
        initialColor: String = NewSessionFormModel.noColor,
        agents: [String] = NewSessionFormModel.defaultAgents,
        colors: [String] = NewSessionFormModel.defaultColors
    ) {
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

    /// The model id this launch passes on: the field's text, trimmed. Empty means no override.
    public var selectedModel: String {
        clean(modelText) ?? ""
    }

    /// The resolved models that match what's typed, at most `maxModelSuggestions`. Text that is exactly
    /// one of them (the prefilled default, a picked suggestion) lists them all, so the field browses.
    public var modelSuggestions: [SessionModelOption] {
        let query = selectedModel.lowercased()
        let browsing = query.isEmpty || modelOptions.contains { $0.id.lowercased() == query }
        let matches = browsing ? modelOptions : modelOptions.filter { $0.id.lowercased().contains(query) }
        return Array(matches.prefix(Self.maxModelSuggestions))
    }

    /// The model dropdown shows while the field is focused and has something to offer: not a lone row
    /// that is already the field's text.
    public var showsModelSuggestions: Bool {
        let suggestions = modelSuggestions
        let onlyTheText = suggestions.count == 1 && suggestions[0].id == selectedModel
        return focusedField == .model && !modelSuggestionsDismissed && !suggestions.isEmpty && !onlyTheText
    }

    public mutating func dismissModelSuggestions() {
        modelSuggestionsDismissed = true
    }

    public var highlightedModelSuggestion: SessionModelOption? {
        value(at: highlightedModelIndex, in: modelSuggestions)
    }

    /// Typing in the model field: from here on resolves leave the text alone.
    public mutating func typeModel(_ text: String) {
        modelText = text
        modelTextEdited = true
        highlightedModelIndex = 0
        modelSuggestionsDismissed = false
    }

    public mutating func moveModelHighlight(_ delta: Int) {
        let count = modelSuggestions.count
        guard count > 0 else {
            return
        }
        highlightedModelIndex = (highlightedModelIndex + delta + count) % count
    }

    /// Puts the highlighted suggestion's id in the field. False when there's nothing to accept, or the
    /// field already holds it.
    @discardableResult
    public mutating func acceptHighlightedModel() -> Bool {
        guard let option = highlightedModelSuggestion, option.id != modelText else {
            return false
        }
        typeModel(option.id)
        modelSuggestionsDismissed = true
        return true
    }

    /// Whether the form can be submitted: a path is all it needs.
    public var canSubmit: Bool {
        !submitting && clean(path) != nil
    }

    /// The selected reasoning-effort level, empty when nothing is selected.
    public var selectedReasoningEffort: String {
        selectedEffortOption?.id ?? ""
    }

    public var selectedEffortOption: SessionReasoningEffortOption? {
        selectedEffortIndex.flatMap { value(at: $0, in: effortOptions) }
    }

    /// Whether the model reports effort levels. Without them the effort segment is inert.
    public var hasEffortLevels: Bool {
        !effortOptions.isEmpty
    }

    /// The effort segment's text: the chosen level's id, or "default".
    public var effortLabel: String {
        selectedEffortOption?.label ?? Self.defaultEffortLabel
    }

    /// Replaces the model suggestions with what the backend resolved for the
    /// current agent's master role. Until the user types in the field, it
    /// takes `defaultModel` (whatever Settings currently has configured, if
    /// anything), as the old model select pre-selected it.
    public mutating func setModelOptions(_ models: [SessionModelOption], defaultModel: String = "") {
        // A whitespace-only id launches without an override, so it is no suggestion.
        modelOptions = models.filter { !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !modelTextEdited {
            modelText = defaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        highlightedModelIndex = 0
    }

    /// Drops the suggestions, for when they stop applying (the agent changed)
    /// or a fetch failed. Untyped text (a default) goes with them.
    public mutating func resetModelOptions() {
        modelOptions = []
        if !modelTextEdited {
            modelText = ""
        }
        highlightedModelIndex = 0
    }

    /// Replaces the reasoning-effort list with what the backend resolved for
    /// the current agent's master role and model. Mirrors `setModelOptions`'s
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
    /// stops applying (the agent or model changed) or a fetch failed.
    public mutating func resetEffortOptions() {
        effortOptions = []
        selectedEffortIndex = nil
        hasResolvedEffortOptions = false
    }

    /// Cycles the reasoning effort through the model's levels and "default", independent of focus (see
    /// `NewSessionEffortKey`). A model without levels has nothing to cycle.
    public mutating func cycleReasoningEffort(_ delta: Int = 1) {
        guard !submitting, hasEffortLevels else {
            return
        }
        selectedEffortIndex = cycleOptionalIndex(selectedEffortIndex, delta: delta, count: effortOptions.count)
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

    /// Steps through `formOrder`, past the effort segment while the model reports no levels.
    private mutating func moveFocus(_ delta: Int) {
        let fields = NewSessionField.formOrder.filter { $0 != .effort || hasEffortLevels }
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
            // the agent actually changed, so cycling a
            // single-agent list doesn't needlessly drop an already-resolved
            // list.
            if selectedAgent != previousAgent {
                modelTextEdited = false
                resetModelOptions()
                resetEffortOptions()
            }
        case .effort:
            cycleReasoningEffort(delta)
        case .color:
            selectedColorIndex = wrapped(selectedColorIndex + delta, count: colors.count)
        case .path, .title, .model, .prompt:
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
