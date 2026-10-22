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
}
