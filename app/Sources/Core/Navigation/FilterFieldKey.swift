import Foundation

/// What a filter field does with a key it takes (`FilterFieldKey`). Each filter applies it to its own model: the
/// Quest Log's (`QuestLogFilter.handleCommand`) and the artifact dock's (`DockPaneModel.handleArtifactFilterCommand`).
public enum FilterFieldCommand: Equatable {
    /// ↑/↓ or ⌃p/⌃n with suggestions showing: moves the highlight by one. -1 is up, +1 down.
    case moveSuggestion(Int)
    /// ↑/↓ or ⌃p/⌃n with no suggestions: moves the list's cursor by one, the same way.
    case moveList(Int)
    /// Tab, or Return, with a suggestion showing: takes the highlighted one.
    case acceptSuggestion
    /// Return with no suggestion showing: the filter stays applied, the cursor goes to the list's first match, and
    /// the keys go back to the list. The filter never acts on a row.
    case returnToList
    /// Backspace in an empty field: removes the last filter chip.
    case removeLastChip
    /// Esc or ⌃[ with suggestions showing: hides them.
    case hideSuggestions
    /// Esc or ⌃[ with no suggestion showing: the keys go back to the list, the filter stays, and the cursor stays where it was.
    case leave
}

/// The keys the Quest Log's and the artifact dock's filter fields share. The fields type text, so letters never move
/// the list here: it moves with ↑/↓ and ⌃p/⌃n. Nil for a key the text system takes: a typed character, Tab with
/// nothing to take, Backspace in a non-empty field, and any key with a modifier that isn't listed.
public enum FilterFieldKey {
    /// `showsSuggestions`: a suggestion is showing, so the keys act on it rather than on the list.
    /// `queryIsEmpty` and `hasChips` decide what Backspace removes.
    public static func command(
        _ press: Keymap.KeyPress,
        showsSuggestions: Bool,
        queryIsEmpty: Bool,
        hasChips: Bool
    ) -> FilterFieldCommand? {
        if Keymap.matches(press, .suggestionUp) || Keymap.matches(press, .suggestionPrevious) {
            return showsSuggestions ? .moveSuggestion(-1) : .moveList(-1)
        }
        if Keymap.matches(press, .suggestionDown) || Keymap.matches(press, .suggestionNext) {
            return showsSuggestions ? .moveSuggestion(1) : .moveList(1)
        }
        if Keymap.matches(press, .tab) {
            return showsSuggestions ? .acceptSuggestion : nil
        }
        if Keymap.matches(press, .submit) {
            return showsSuggestions ? .acceptSuggestion : .returnToList
        }
        if Keymap.matches(press, .backspace) {
            return queryIsEmpty && hasChips ? .removeLastChip : nil
        }
        if Keymap.matches(press, .cancel) {
            return showsSuggestions ? .hideSuggestions : .leave
        }
        return nil
    }
}
