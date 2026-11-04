import Foundation

/// What a modal does with a key its focused field didn't take (`ModalKeys.command`).
public enum ModalCommand: Equatable {
    case submit
    case cancel
    /// Moves to the next field, or the next row of a list: Tab, ⌃J, ⇧⌘J, and j in a modal with no text field.
    case nextField
    /// Moves back: ⇧Tab, ⌃K, ⇧⌘K, and k in a modal with no text field.
    case previousField
    /// ← / h and → / l, and ⇧⌘H / ⇧⌘L, step the focused select's value: -1 back, +1 forward.
    case cycle(Int)
    /// A key the modal takes and does nothing with: Tab or j with nothing to move between, or any key while a submit
    /// is in flight. The text system never sees it.
    case consume
}

/// The modal state the shared keys read. A sheet builds it from its model for each key.
public struct ModalKeyContext: Equatable {
    /// What the focused field is. Nil when the modal has no field, as the delete confirmation has none.
    public enum Focus: Equatable {
        /// A select: ← / → cycle its value.
        case select
        /// A single-line field: Return submits, and the text takes the other keys.
        case line
        /// The multi-line prompt. Its editor takes Return (creates; ⇧Return adds a line), ⌃s, and Tab (types a tab).
        case prompt
    }

    public var focus: Focus?
    /// The fields Tab moves between, or the rows j and k move through. With one, moving does nothing.
    public var fieldCount: Int
    /// The modal has a text field of its own. Such a form moves between its fields with Tab, ⇧Tab, ⌃J and ⌃K, from a
    /// select too, and j and k type. A modal with none moves its rows or select fields with j and k, and its Tab,
    /// ⇧Tab, ⌃J and ⌃K take the press and do nothing.
    public var hasTextFields: Bool
    /// A submit is in flight: every key is held except Esc, which still closes.
    public var submitting: Bool
    /// Whether Return and ⌘Return submit. Settings applies each change as it is made, so it submits nothing.
    public var submits: Bool

    public init(focus: Focus?, fieldCount: Int, hasTextFields: Bool, submitting: Bool, submits: Bool) {
        self.focus = focus
        self.fieldCount = fieldCount
        self.hasTextFields = hasTextFields
        self.submitting = submitting
        self.submits = submits
    }

    /// The focused part is a line or the prompt, so ↑ and ↓ move its caret and j and k type into it.
    var focusIsText: Bool {
        focus == .line || focus == .prompt
    }

    /// The focused part takes typed letters. A colour's search is a line in a modal with no text field of its own, so
    /// the focus decides for it.
    var typesText: Bool {
        hasTextFields || focusIsText
    }
}

/// The keys every modal shares. A sheet's focused field takes its own keys first (a picker's, the path's, the
/// prompt's); what they leave comes here. Nil means the press belongs to the focused text: typing, the caret, the
/// prompt editor's Return.
///
/// A list is a modal with no text field, so j and k move it, and ↑ and ↓ never do: they move a suggestion dropdown
/// (taken before this) or a text field's caret.
public enum ModalKeys {
    /// ↓ and ↑ by key code.
    private static let verticalArrowKeyCodes: Set<UInt16> = [125, 126]

    public static func command(for press: Keymap.KeyPress, in context: ModalKeyContext) -> ModalCommand? {
        if context.submitting {
            return Keymap.matches(press, .cancel) ? .cancel : .consume
        }
        if Keymap.matches(press, .cancel) {
            return .cancel
        }
        if let direction = Keymap.NavigationChord.direction(for: press) {
            return navigation(direction, in: context)
        }
        if Keymap.matches(press, .submit) {
            return submission(press, in: context)
        }
        if Keymap.matches(press, .tab) {
            return isPrompt(context.focus) ? nil : fieldStep(1, in: context)
        }
        if Keymap.matches(press, .backTab) {
            return fieldStep(-1, in: context)
        }
        if Keymap.matches(press, .nextField) {
            return fieldStep(1, in: context)
        }
        if Keymap.matches(press, .previousField) {
            return fieldStep(-1, in: context)
        }
        if Keymap.matches(press, .modalMoveDown) {
            return rowStep(1, in: context)
        }
        if Keymap.matches(press, .modalMoveUp) {
            return rowStep(-1, in: context)
        }
        if isPlainVerticalArrow(press) {
            return context.focusIsText ? nil : .consume
        }
        guard let step = cycleStep(press), context.focus == .select else {
            return nil
        }
        return .cycle(step)
    }

    /// The step a select's cycle key takes: -1 for ← and h, +1 for → and l. Nil for another key.
    public static func cycleStep(_ press: Keymap.KeyPress) -> Int? {
        if Keymap.matches(press, .cycleLeft) {
            return -1
        }
        if Keymap.matches(press, .cycleRight) {
            return 1
        }
        return nil
    }

    /// ⇧⌘J and ⇧⌘K move through the modal's fields or rows, ⇧⌘H and ⇧⌘L cycle a select. A modal owns these chords, so
    /// each one is taken even when it does nothing.
    private static func navigation(_ direction: NavigationDirection, in context: ModalKeyContext) -> ModalCommand {
        switch direction {
        case .down:
            return moveFocus(1, in: context)
        case .up:
            return moveFocus(-1, in: context)
        case .left:
            return cycle(-1, in: context)
        case .right:
            return cycle(1, in: context)
        }
    }

    /// Return and ⌘Return submit. Return in a prompt is the editor's own, so it passes; ⌘Return submits from anywhere.
    private static func submission(_ press: Keymap.KeyPress, in context: ModalKeyContext) -> ModalCommand? {
        guard context.submits else {
            return nil
        }
        if press.modifiers.contains(.command) {
            return .submit
        }
        if isPrompt(context.focus) {
            return nil
        }
        return .submit
    }

    /// Tab, ⇧Tab, ⌃J and ⌃K: between fields in a form with text fields, and nothing in a list.
    private static func fieldStep(_ delta: Int, in context: ModalKeyContext) -> ModalCommand {
        context.typesText ? moveFocus(delta, in: context) : .consume
    }

    /// j and k: the typed letters in a form with text fields, and a step through the rows or select fields otherwise.
    private static func rowStep(_ delta: Int, in context: ModalKeyContext) -> ModalCommand? {
        context.typesText ? nil : moveFocus(delta, in: context)
    }

    private static func isPlainVerticalArrow(_ press: Keymap.KeyPress) -> Bool {
        press.modifiers.isEmpty && verticalArrowKeyCodes.contains(press.keyCode)
    }

    private static func moveFocus(_ delta: Int, in context: ModalKeyContext) -> ModalCommand {
        guard context.fieldCount > 1 else {
            return .consume
        }
        return delta > 0 ? .nextField : .previousField
    }

    private static func cycle(_ step: Int, in context: ModalKeyContext) -> ModalCommand {
        context.focus == .select ? .cycle(step) : .consume
    }

    private static func isPrompt(_ focus: ModalKeyContext.Focus?) -> Bool {
        guard case .prompt? = focus else {
            return false
        }
        return true
    }
}
