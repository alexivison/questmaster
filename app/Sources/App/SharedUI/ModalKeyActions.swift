import AppKit
import QuestmasterCore

/// A modal's keys: the focused field's own key first, then the shared modal keys (`ModalKeys`), each running the
/// sheet's action. A sheet builds one in its model's `handle(_:)` and hands `handle` to `SheetKeyEventMonitor`.
struct ModalKeyActions {
    /// The state the shared keys read, as it stands for this press.
    var context: () -> ModalKeyContext
    /// The focused field's own keys: a picker's, the path's, a select's class key. True when the field took the press.
    var fieldKey: (NSEvent) -> Bool = { _ in false }
    var submit: () -> Void
    var cancel: () -> Void
    /// Moves focus by one field: +1 forward, -1 back.
    var moveFocus: (Int) -> Void = { _ in }
    /// Steps the focused select's value: -1 back, +1 forward.
    var cycle: (Int) -> Void = { _ in }

    /// True when the modal took the press, so the text system never sees it.
    func handle(_ event: NSEvent) -> Bool {
        if !context().submitting, fieldKey(event) {
            return true
        }
        guard let command = ModalKeys.command(for: event.keymapPress, in: context()) else {
            return false
        }
        switch command {
        case .submit:
            submit()
        case .cancel:
            cancel()
        case .nextField:
            moveFocus(1)
        case .previousField:
            moveFocus(-1)
        case .cycle(let step):
            cycle(step)
        case .consume:
            break
        }
        return true
    }
}
