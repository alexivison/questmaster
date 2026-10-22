import Foundation

/// The model and colour fields are pickers until you type into them. SELECT (on focus): no caret; the
/// field takes its picker keys (e for effort, ←/→ for colours), and any printable key, Backspace or
/// Return starts SEARCH. SEARCH is a plain text field; picking a suggestion, Esc, or leaving the field
/// returns to SELECT.
public enum PickerFieldMode: Equatable {
    case select
    case search

    /// How a SELECT-state key starts a search.
    public enum SearchStart: Equatable {
        /// A printable key: the search starts on that text.
        case seed(String)
        /// Backspace or Return: the search starts editing the current text.
        case editCurrent
    }

    /// The search a key starts from SELECT, or nil when it isn't one (a modified key, Tab, Esc, an arrow,
    /// or anything else without printable text). The field takes its own picker keys before asking.
    public static func searchStart(characters: String?, keyCode: UInt16, command: Bool, control: Bool, option: Bool) -> SearchStart? {
        guard !command, !control, !option else {
            return nil
        }
        if Keymap.PickerField.editCurrent.matches(keyCode) {
            return .editCurrent
        }
        guard !Keymap.PickerField.notText.matches(keyCode), let characters, !characters.isEmpty else {
            return nil
        }
        let printable = characters.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar) && !(0xF700...0xF8FF).contains(scalar.value)
        }
        return printable ? .seed(characters) : nil
    }

    /// The items matching a search, best first: an exact match, then those starting with the query,
    /// then those containing it, each group in the items' own order. `key` is the lowercased text to match.
    public static func ranked<Item>(_ items: [Item], query: String, key: (Item) -> String) -> [Item] {
        var exact: [Item] = []
        var prefix: [Item] = []
        var contains: [Item] = []
        for item in items {
            let text = key(item)
            if text == query {
                exact.append(item)
            } else if text.hasPrefix(query) {
                prefix.append(item)
            } else if text.contains(query) {
                contains.append(item)
            }
        }
        return exact + prefix + contains
    }

    /// Where the caret goes as a picker field's mode changes.
    public enum CaretChange: Equatable {
        /// A search started: into the text.
        case intoText
        /// The field returned to SELECT and keeps focus: out of the text (the sheet's focus sink).
        case outOfText
    }

    /// How the caret follows a picker field's mode. A search that ended because focus left the field
    /// leaves the caret to wherever focus went: taking it here would race the field that now has focus.
    public static func caretChange(from before: PickerFieldMode, to after: PickerFieldMode, fieldFocused: Bool) -> CaretChange? {
        guard fieldFocused, before != after else {
            return nil
        }
        return after == .search ? .intoText : .outOfText
    }
}
