import AppKit
import Observation
import QuestmasterCore

/// The Quest Log's filter field: free text plus `@type:` and `@size:` tokens with suggestions. The tokens narrow the
/// list along with the text; the project tabs (`QuestLogStore`) pick the project. The field shares its parsing and
/// keys with the artifact filter (`DockPaneModel.filterTrigger`, `FilterBar`).
@Observable
@MainActor
final class QuestLogFilter {
    /// The token prefixes this field takes.
    static let kinds: [FilterTokenKind] = [.type, .size]

    private(set) var query = ""
    private(set) var tokens: [ArtifactFilterToken] = []
    private(set) var suggestions: [ArtifactFilterSuggestion] = []
    private(set) var selectedSuggestionID: String?
    /// Bumped to move keyboard focus into the field.
    private(set) var focusNonce = 0
    private var suggestionIndex = 0
    private var suggestionsHidden = false
    private var tracker = TrackerSnapshot(repos: [])

    /// The filter changed: re-sync the list.
    @ObservationIgnored var onChange: (() -> Void)?
    /// The list's cursor moves: ⌃p and ⌃n with no suggestion open, and Return, which moves it to the first quest.
    @ObservationIgnored var onMoveSelection: ((ListCommand) -> Void)?
    /// The keys go back to the list: Esc or Return with no suggestion open. The filter stays; the next Esc closes the log.
    @ObservationIgnored var onLeave: (() -> Void)?

    /// The text and tag selections the list keeps.
    var search: QuestListFilter {
        QuestListFilter(text: textQuery, types: selectedValues(of: .type), sizes: selectedValues(of: .size))
    }

    /// The text part of the query: everything before an `@` token still being typed.
    var textQuery: String {
        guard let trigger = DockPaneModel.filterTrigger(in: query, kinds: Self.kinds) else {
            return query.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(query[..<trigger.range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func update(tracker: TrackerSnapshot) {
        self.tracker = tracker
        refreshSuggestions()
    }

    func focus() {
        focusNonce &+= 1
    }

    func setQuery(_ next: String) {
        guard query != next else {
            return
        }
        query = next
        suggestionIndex = 0
        suggestionsHidden = false
        changed()
    }

    func removeToken(_ token: ArtifactFilterToken) {
        removeToken(kind: token.kind, value: token.value)
        focusNonce &+= 1
        changed()
    }

    @discardableResult
    func acceptSuggestion(_ suggestion: ArtifactFilterSuggestion? = nil) -> Bool {
        guard let trigger = DockPaneModel.filterTrigger(in: query, kinds: Self.kinds) else {
            return false
        }
        guard let selected = suggestion ?? suggestions.first(where: { $0.id == selectedSuggestionID }) else {
            return false
        }
        switch selected.mode {
        case .command:
            query.replaceSubrange(trigger.range, with: selected.kind.command)
        case .value:
            addToken(kind: selected.kind, value: selected.value, title: selected.tokenTitle)
            query = DockPaneModel.filterQueryPrefix(in: query, before: trigger.range)
        }
        suggestionIndex = 0
        suggestionsHidden = false
        focusNonce &+= 1
        changed()
        return true
    }

    /// The filter is the Quest Log's one text field, so Tab, ⌃J and ⌃K have no other field to move to and take nothing.
    private static let keysInTheField = ModalKeyContext(focus: .line, fieldCount: 1, hasTextFields: true, submitting: false, submits: false)

    /// The field's own keys (each press from `CommandTextField`). True when the filter took the press. With no suggestion
    /// open, ↑/↓ are the caret's, since the list moves with j and k; ⌃p and ⌃n still move the list.
    func handleCommand(_ press: Keymap.KeyPress) -> Bool {
        guard let command = FilterFieldKey.command(
            press,
            showsSuggestions: !suggestions.isEmpty,
            arrowsMoveList: false,
            queryIsEmpty: query.isEmpty,
            hasChips: !tokens.isEmpty
        ) else {
            return ModalKeys.command(for: press, in: Self.keysInTheField) == .consume
        }
        apply(command)
        return true
    }

    private func apply(_ command: FilterFieldCommand) {
        switch command {
        case .moveSuggestion(let delta):
            moveSuggestion(delta: delta)
        case .moveList(let delta):
            onMoveSelection?(.move(delta > 0 ? 1 : -1))
        case .acceptSuggestion:
            acceptSuggestion()
        case .returnToList:
            onMoveSelection?(.jumpToTop)
            onLeave?()
        case .removeLastChip:
            tokens.removeLast()
            changed()
        case .hideSuggestions:
            suggestionsHidden = true
            refreshSuggestions()
        case .leave:
            onLeave?()
        }
    }

    private func changed() {
        refreshSuggestions()
        onChange?()
    }

    private func refreshSuggestions() {
        let next = makeSuggestions()
        if suggestionIndex >= next.count {
            suggestionIndex = 0
        }
        suggestions = next
        selectedSuggestionID = next.isEmpty ? nil : next[suggestionIndex].id
    }

    private func moveSuggestion(delta: Int) {
        guard !suggestions.isEmpty else {
            return
        }
        suggestionIndex = DockPaneModel.wrapped(suggestionIndex + delta, count: suggestions.count)
        selectedSuggestionID = suggestions[suggestionIndex].id
    }

    private func addToken(kind: FilterTokenKind, value: String, title: String) {
        guard Self.kinds.contains(kind),
              !value.isEmpty,
              !tokens.contains(where: { $0.kind == kind && $0.value == value }) else {
            return
        }
        tokens.append(ArtifactFilterToken(kind: kind, value: value, title: title))
    }

    private func removeToken(kind: FilterTokenKind, value: String) {
        tokens.removeAll { $0.kind == kind && $0.value == value }
    }

    private func selectedValues(of kind: FilterTokenKind) -> Set<String> {
        Set(tokens.filter { $0.kind == kind }.map(\.value))
    }

    private func makeSuggestions() -> [ArtifactFilterSuggestion] {
        guard !suggestionsHidden, let trigger = DockPaneModel.filterTrigger(in: query, kinds: Self.kinds) else {
            return []
        }
        switch trigger.mode {
        case .command:
            let commandQuery = trigger.query.lowercased()
            return Self.kinds
                .filter { commandQuery.isEmpty || $0.rawValue.hasPrefix(commandQuery) }
                .map { kind in
                    ArtifactFilterSuggestion(mode: .command, kind: kind, value: kind.rawValue, title: kind.command, detail: "filter", tokenTitle: "")
                }
        case .value:
            guard let kind = trigger.kind else {
                return []
            }
            let selected = selectedValues(of: kind)
            return options(for: kind)
                .filter { !selected.contains($0.id) }
                .filter { DockPaneModel.fuzzyMatch(trigger.query, in: $0.id) || DockPaneModel.fuzzyMatch(trigger.query, in: $0.title) }
                .map { option in
                    ArtifactFilterSuggestion(
                        mode: .value,
                        kind: kind,
                        value: option.id,
                        title: "\(kind.command)\(option.title)",
                        detail: String(quests(tagged: kind, with: option.id).count),
                        tokenTitle: option.title
                    )
                }
        }
    }

    private func options(for kind: FilterTokenKind) -> [ArtifactFilterOption] {
        switch kind {
        case .size:
            QuestSize.allCases.map { ArtifactFilterOption(id: $0.rawValue, title: $0.rawValue) }
        case .type:
            QuestTagType.allCases.map { ArtifactFilterOption(id: $0.rawValue, title: $0.displayName) }
        case .project:
            []
        }
    }

    /// The quests that carry a tag, as the suggestion's count.
    private func quests(tagged kind: FilterTokenKind, with value: String) -> [QuestItem] {
        tracker.quests.filter { quest in
            kind == .size ? quest.size == value : quest.types.contains(value)
        }
    }
}
