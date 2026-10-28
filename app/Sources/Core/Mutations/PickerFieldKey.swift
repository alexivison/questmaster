import Foundation

/// What a picker field does with a key it takes (`PickerFieldKey`). Each field applies it to its own model:
/// `ColorFieldModel.apply`, `NewSessionFormModel.applyModelCommand`, `NewQuestFormModel.applyProjectCommand`.
public enum PickerFieldCommand: Equatable {
    /// SELECT: a printable key or Backspace starts a search.
    case startSearch(PickerFieldMode.SearchStart)
    /// SEARCH: ↑/↓ or ⌃p/⌃n move the highlight.
    case moveHighlight(Int)
    /// SEARCH, with a row showing: Tab or Return takes the highlighted row. The search ends and the caret stays.
    case pick
    /// SEARCH, with no row to take: Tab or Return ends the search, keeping the value.
    case endSearch
    /// SEARCH: Esc ends the search and goes back to the value the search started from.
    case restore
}

/// The keys the colour, model, project and path fields share, so they behave the same. Nil for a key the field
/// doesn't take: the sheet's (Tab, Return and Esc in SELECT), a ⌘ key, ⇧Tab, and any key the text system types
/// while searching. A field checks its own keys (colour cycling, effort, ⌃r) before asking.
public enum PickerFieldKey {
    /// `showsSuggestions`: a row is showing, so Tab or Return takes the highlighted one rather than ending the search.
    public static func command(_ press: Keymap.KeyPress, mode: PickerFieldMode, showsSuggestions: Bool) -> PickerFieldCommand? {
        guard !press.modifiers.contains(.command) else {
            return nil
        }
        switch mode {
        case .select:
            return PickerFieldMode.searchStart(press).map(PickerFieldCommand.startSearch)
        case .search:
            return searchCommand(press, showsSuggestions: showsSuggestions)
        }
    }

    private static func searchCommand(_ press: Keymap.KeyPress, showsSuggestions: Bool) -> PickerFieldCommand? {
        if Keymap.matches(press, .suggestionPrevious) {
            return .moveHighlight(-1)
        }
        if Keymap.matches(press, .suggestionNext) {
            return .moveHighlight(1)
        }
        if Keymap.matches(press, .suggestionUp) {
            return .moveHighlight(-1)
        }
        if Keymap.matches(press, .suggestionDown) {
            return .moveHighlight(1)
        }
        if Keymap.matches(press, .cancel) {
            return .restore
        }
        guard Keymap.matches(press, .tab) || Keymap.matches(press, .submit) else {
            return nil
        }
        return showsSuggestions ? .pick : .endSearch
    }
}

/// What Tab does in a typed path's field (`SuggestionList.tabOutcome`).
public enum PathTabOutcome: Equatable {
    /// The path becomes this: the highlighted row, or the completion from disk. The rows close.
    case choose(String)
    /// Nothing to take or complete: Tab moves on to the next field.
    case moveOn
}
