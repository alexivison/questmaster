import Foundation

public enum NewSessionField: CaseIterable, Equatable, Hashable {
    case path
    case title
    case agent
    case model
    /// Edit Session's colour select. New Session has no colour field: a new session takes the default.
    case color
    case prompt

    public var isSelect: Bool {
        self == .agent || self == .color
    }

    /// New Session's inputs, top to bottom: the order ⌃j / ⌃k and Tab move through. The model field's
    /// effort segment is no stop of its own.
    public static let formOrder: [NewSessionField] = [.path, .title, .agent, .model, .prompt]
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

/// The keys that cycle the reasoning effort, the model field's alone: ⌃e in both of its states, and plain
/// e in SELECT, where an e can't be typed. With focus anywhere else neither does anything effort-related.
public enum NewSessionEffortKey {
    public static func cycles(_ press: Keymap.KeyPress, field: NewSessionField, mode: PickerFieldMode) -> Bool {
        guard field == .model, Keymap.matches(press, .cycleEffort) else {
            return false
        }
        return press.modifiers.contains(.control) || mode == .select
    }
}

/// ⌃r refetches the models past the backend's catalog cache, while the model field has focus (the path
/// field's own ⌃r lists its recent directories).
public enum NewSessionModelRefreshKey {
    public static func refreshes(_ press: Keymap.KeyPress, field: NewSessionField) -> Bool {
        field == .model && Keymap.matches(press, .refreshModels)
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
    /// Nil is Random: no class is sent, and the backend picks one.
    public let sessionClass: SessionClass?
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

    /// Leaving the model field ends its search, keeping what was typed.
    public var focusedField: NewSessionField {
        didSet {
            if focusedField != .model, modelMode == .search {
                endModelSearch(keepingText: true)
            }
        }
    }
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
    /// The highlight over all of `modelMatches`, and the `maxModelSuggestions` rows following it.
    public private(set) var modelWindow = PickerListWindow(visibleRows: NewSessionFormModel.maxModelSuggestions)
    /// Esc, or accepting a suggestion, puts the model dropdown away until the next keystroke.
    public private(set) var modelSuggestionsDismissed = false
    /// The model field is a picker field (`PickerFieldMode`): SELECT until a key starts a search.
    public private(set) var modelMode = PickerFieldMode.select
    /// What Esc restores: the text, and whether it was typed, as the search started.
    private var modelTextBeforeSearch = ""
    private var modelTextEditedBeforeSearch = false
    public private(set) var selectedEffortIndex: Int?
    /// The new master's class; nil is Random, New Session's default.
    public private(set) var sessionClass: SessionClass?
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

    /// The resolved models that match what's typed, best first (`PickerFieldMode.ranked`). An empty
    /// field, or the text the search started from, browses every model.
    public var modelMatches: [SessionModelOption] {
        guard !isBrowsingModels else {
            return modelOptions
        }
        return PickerFieldMode.ranked(modelOptions, query: selectedModel.lowercased()) { $0.id.lowercased() }
    }

    /// The dropdown's rows: `maxModelSuggestions` of the matches, following the highlight.
    public var modelSuggestions: [SessionModelOption] {
        modelWindow.visible(modelMatches)
    }

    /// The highlighted row's position among `modelSuggestions`.
    public var visibleModelHighlightIndex: Int {
        modelWindow.visibleHighlightIndex
    }

    private var isBrowsingModels: Bool {
        selectedModel.isEmpty || modelText == modelTextBeforeSearch
    }

    /// The best match, or the current model while the list browses.
    private mutating func resetModelHighlight() {
        let matches = modelMatches
        modelWindow.reset(highlighting: isBrowsingModels ? matches.firstIndex { $0.id == selectedModel } ?? 0 : 0, count: matches.count)
    }

    /// The model dropdown shows while the field is focused and has something to offer: not a lone row
    /// that is already the field's text.
    public var showsModelSuggestions: Bool {
        let suggestions = modelMatches
        let onlyTheText = suggestions.count == 1 && suggestions[0].id == selectedModel
        return focusedField == .model && modelMode == .search && !modelSuggestionsDismissed && !suggestions.isEmpty && !onlyTheText
    }

    /// A key, or a click into the text, starts a search: on that text, or editing the model id.
    public mutating func startModelSearch(_ start: PickerFieldMode.SearchStart) {
        modelTextBeforeSearch = modelText
        modelTextEditedBeforeSearch = modelTextEdited
        modelMode = .search
        switch start {
        case .seed(let text):
            typeModel(text)
        case .editCurrent:
            resetModelHighlight()
            modelSuggestionsDismissed = false
        }
    }

    /// Back to SELECT. Esc restores the text the search started from; picking or leaving keeps what was
    /// typed, since the field takes any id.
    public mutating func endModelSearch(keepingText: Bool) {
        if !keepingText {
            modelText = modelTextBeforeSearch
            modelTextEdited = modelTextEditedBeforeSearch
        }
        modelMode = .select
        modelSuggestionsDismissed = true
    }

    public mutating func dismissModelSuggestions() {
        modelSuggestionsDismissed = true
    }

    public var highlightedModelSuggestion: SessionModelOption? {
        modelWindow.highlighted(modelMatches)
    }

    /// Typing in the model field: from here on resolves leave the text alone.
    public mutating func typeModel(_ text: String) {
        modelText = text
        modelTextEdited = true
        resetModelHighlight()
        modelSuggestionsDismissed = false
    }

    public mutating func moveModelHighlight(_ delta: Int) {
        modelWindow.move(delta, count: modelMatches.count)
    }

    /// Puts the highlighted suggestion's id in the field and returns to SELECT. False when there's
    /// nothing to accept.
    @discardableResult
    public mutating func acceptHighlightedModel() -> Bool {
        guard showsModelSuggestions, let option = highlightedModelSuggestion else {
            return false
        }
        typeModel(option.id)
        endModelSearch(keepingText: true)
        return true
    }

    /// The shared picker keys (`PickerFieldKey`) applied to the model field.
    public mutating func applyModelCommand(_ command: PickerFieldCommand) {
        switch command {
        case .startSearch(let start):
            startModelSearch(start)
        case .moveHighlight(let delta):
            moveModelHighlight(delta)
        case .pick:
            acceptHighlightedModel()
        case .endSearch:
            endModelSearch(keepingText: true)
        case .restore:
            endModelSearch(keepingText: false)
        }
    }

    /// The title field's trailing segment: the chosen class's name, or "Random".
    public var classLabel: String {
        sessionClass?.displayName ?? SessionClass.randomLabel
    }

    /// Cycles the class through Random and the seven classes, independent of focus (see `SessionClassKey`).
    public mutating func cycleSessionClass() {
        guard !submitting else {
            return
        }
        sessionClass = SessionClass.next(after: sessionClass)
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
        resetModelHighlight()
    }

    /// Drops the suggestions, for when they stop applying (the agent changed)
    /// or a fetch failed. Untyped text (a default) goes with them.
    public mutating func resetModelOptions() {
        modelOptions = []
        if !modelTextEdited {
            modelText = ""
        }
        resetModelHighlight()
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
            sessionClass: sessionClass,
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
        let fields = NewSessionField.formOrder
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
