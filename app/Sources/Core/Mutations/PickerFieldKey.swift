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
    public static func command(keyCode: UInt16, characters: String?, modifiers: Set<Keymap.Modifier>, mode: PickerFieldMode, showsSuggestions: Bool) -> PickerFieldCommand? {
        guard !modifiers.contains(.command) else {
            return nil
        }
        switch mode {
        case .select:
            return PickerFieldMode.searchStart(characters: characters, keyCode: keyCode, modifiers: modifiers).map(PickerFieldCommand.startSearch)
        case .search:
            return searchCommand(keyCode: keyCode, characters: characters, modifiers: modifiers, showsSuggestions: showsSuggestions)
        }
    }

    private static func searchCommand(keyCode: UInt16, characters: String?, modifiers: Set<Keymap.Modifier>, showsSuggestions: Bool) -> PickerFieldCommand? {
        if modifiers.contains(.control) {
            return controlCommand(keyCode: keyCode)
        }
        guard !modifiers.contains(.option) else {
            return nil
        }
        if Keymap.PickerField.suggestionUp.matches(keyCode) {
            return .moveHighlight(-1)
        }
        if Keymap.PickerField.suggestionDown.matches(keyCode) {
            return .moveHighlight(1)
        }
        if Keymap.NewSession.cancel.matches(keyCode) {
            return .restore
        }
        let tab = Keymap.NewSession.completePath.matches(keyCode) && !modifiers.contains(.shift)
        guard tab || Keymap.NewSession.create.matches(characters) else {
            return nil
        }
        return showsSuggestions ? .pick : .endSearch
    }

    /// ⌃p and ⌃n while searching; the field's other ⌃ keys (⌃e, ⌃r, ⌃j, ⌃k) are not the picker's.
    private static func controlCommand(keyCode: UInt16) -> PickerFieldCommand? {
        if Keymap.PickerField.suggestionUpControl.matches(keyCode) {
            return .moveHighlight(-1)
        }
        if Keymap.PickerField.suggestionDownControl.matches(keyCode) {
            return .moveHighlight(1)
        }
        return nil
    }
}

/// What Tab does in a typed path's field (`SuggestionList.tabOutcome`).
public enum PathTabOutcome: Equatable {
    /// The path becomes this: the highlighted row, or the completion from disk. The rows close.
    case choose(String)
    /// Nothing to take or complete: Tab moves on to the next field.
    case moveOn
}
