import AppKit
import Observation
import QuestmasterCore

/// The Quest Log's filter field: free text plus `@project:` tokens with suggestions. This is the quest
/// dock's filter (main, 32c8004) moved over unchanged in behaviour. It parses and matches with the
/// artifact filter's helpers on `DockPaneModel`; Core's `QuestDisplayState` does the filtering itself.
@Observable
@MainActor
final class QuestLogFilter {
    private(set) var query = ""
    private(set) var tokens: [ArtifactFilterToken] = []
    private(set) var suggestions: [ArtifactFilterSuggestion] = []
    private(set) var selectedSuggestionID: String?
    /// Bumped to move keyboard focus into the field.
    private(set) var focusNonce = 0
    private(set) var projectIDs: Set<String> = []
    private var suggestionIndex = 0
    private var suggestionsHidden = false
    private var tracker = TrackerSnapshot(repos: [])

    /// The filter changed: re-sync the list.
    @ObservationIgnored var onChange: (() -> Void)?
    /// Return with no suggestion open edits the selected quest, as the dock did.
    @ObservationIgnored var onEdit: (() -> Void)?
    /// Up and down with no suggestion open move the list selection.
    @ObservationIgnored var onMoveSelection: ((QuestLogCommand) -> Void)?
    /// Esc with no suggestion open leaves the field; the next Esc closes the log.
    @ObservationIgnored var onLeave: (() -> Void)?

    var isActive: Bool { !textQuery.isEmpty || !projectIDs.isEmpty }

    /// The text part of the query: everything before an `@` token still being typed.
    var textQuery: String {
        guard let trigger = DockPaneModel.filterTrigger(in: query) else {
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
        guard let trigger = DockPaneModel.filterTrigger(in: query) else {
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

    /// The field's own keys (each press from `CommandTextField`).
    func handleCommand(_ press: Keymap.KeyPress) -> Bool {
        if Keymap.matches(press, .suggestionDown) {
            moveSuggestionOrSelection(delta: 1)
            return true
        }
        if Keymap.matches(press, .suggestionUp) {
            moveSuggestionOrSelection(delta: -1)
            return true
        }
        if Keymap.matches(press, .tab), !suggestions.isEmpty {
            return acceptSuggestion()
        }
        if Keymap.matches(press, .submit) {
            if !suggestions.isEmpty {
                return acceptSuggestion()
            }
            onEdit?()
            return true
        }
        if Keymap.matches(press, .backspace), query.isEmpty, !tokens.isEmpty {
            tokens.removeLast()
            syncProjectIDs()
            changed()
            return true
        }
        if Keymap.matches(press, .cancel) {
            guard !suggestions.isEmpty else {
                onLeave?()
                return true
            }
            suggestionsHidden = true
            refreshSuggestions()
            return true
        }
        return false
    }

    /// ↑ and ↓ move the suggestions while there are any, and the quest list otherwise.
    private func moveSuggestionOrSelection(delta: Int) {
        guard !suggestions.isEmpty else {
            onMoveSelection?(delta > 0 ? .moveDown : .moveUp)
            return
        }
        moveSuggestion(delta: delta)
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

    private func addToken(kind: ArtifactFilterTokenKind, value: String, title: String) {
        guard kind == .project,
              !value.isEmpty,
              !tokens.contains(where: { $0.kind == kind && $0.value == value }) else {
            return
        }
        tokens.append(ArtifactFilterToken(kind: kind, value: value, title: title))
        syncProjectIDs()
    }

    private func removeToken(kind: ArtifactFilterTokenKind, value: String) {
        let next = tokens.filter { $0.kind != kind || $0.value != value }
        guard next != tokens else {
            return
        }
        tokens = next
        syncProjectIDs()
    }

    private func syncProjectIDs() {
        projectIDs = Set(tokens.filter { $0.kind == .project }.map(\.value))
    }

    private func makeSuggestions() -> [ArtifactFilterSuggestion] {
        guard !suggestionsHidden, let trigger = DockPaneModel.filterTrigger(in: query) else {
            return []
        }
        switch trigger.mode {
        case .command:
            let commandQuery = trigger.query.lowercased()
            let kind = ArtifactFilterTokenKind.project
            guard commandQuery.isEmpty || kind.rawValue.hasPrefix(commandQuery) else {
                return []
            }
            return [ArtifactFilterSuggestion(mode: .command, kind: kind, value: kind.rawValue, title: kind.command, detail: "filter", tokenTitle: "")]
        case .value:
            guard trigger.kind == .project else {
                return []
            }
            return projectOptions()
                .filter { !projectIDs.contains($0.id) }
                .filter { DockPaneModel.fuzzyMatch(trigger.query, in: $0.id) || DockPaneModel.fuzzyMatch(trigger.query, in: $0.title) }
                .map { option in
                    ArtifactFilterSuggestion(
                        mode: .value,
                        kind: .project,
                        value: option.id,
                        title: "\(ArtifactFilterTokenKind.project.command)\(option.title)",
                        detail: String(tracker.quests.filter { $0.projectID == option.id }.count),
                        tokenTitle: option.title
                    )
                }
        }
    }

    private func projectOptions() -> [ArtifactFilterOption] {
        var titlesByID: [String: String] = [:]
        for project in tracker.projects {
            guard let id = DockPaneModel.cleanName(project.id), id != "ungrouped" else {
                continue
            }
            titlesByID[id] = DockPaneModel.cleanName(project.name) ?? DockPaneModel.humanProjectName(id)
        }
        for repo in tracker.repos {
            guard let id = DockPaneModel.cleanName(repo.id), id != "ungrouped" else {
                continue
            }
            titlesByID[id] = DockPaneModel.cleanName(repo.name) ?? DockPaneModel.humanProjectName(id)
        }
        for quest in tracker.quests {
            guard let id = DockPaneModel.cleanName(quest.projectID) else {
                continue
            }
            titlesByID[id] = titlesByID[id]
                ?? DockPaneModel.cleanName(quest.projectName)
                ?? DockPaneModel.cleanName(quest.projectPath).map(DockPaneModel.humanProjectName(_:))
                ?? DockPaneModel.humanProjectName(id)
        }
        return titlesByID
            .map { ArtifactFilterOption(id: $0.key, title: $0.value) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
}
