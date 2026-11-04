import Foundation
import QuestmasterCore

struct ModalKeysTests {
    static func run() {
        returnSubmitsFromALineAndASelect()
        returnIsThePromptsOwnAndCommandReturnSubmitsFromAnywhere()
        settingsSubmitsNothing()
        escAndControlBracketCancel()
        submitInFlightHoldsEveryKeyButEsc()
        tabAndBackTabMoveBetweenFields()
        tabWithOneFieldOrNoFieldDoesNothing()
        promptKeepsTabAsText()
        arrowsAndHLCycleASelect()
        cyclingIsOnlyForSelects()
        plainLettersBelongToTheText()
        editRepoAndDeleteConfirmationSubmit()
        tabAndControlJKMoveFromASelectInAFormWithTextFields()
        jAndKTypeInAFormWithTextFields()
        jAndKMoveAListOrASelectOnlyModal()
        tabAndControlJKTakeNothingInAListOrASelectOnlyModal()
        arrowsNeverMoveAModal()
        theRemovedOptionKAliasIsNoFieldKey()
        everyModalsMovementKeys()
        print("ModalKeysTests: all tests passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fail(message)
        }
    }

    private static func fail(_ message: String) -> Never {
        fputs("ModalKeysTests failed: \(message)\n", stderr)
        Foundation.exit(1)
    }

    private static func press(_ character: String?, _ modifiers: Set<Keymap.Modifier> = [], keyCode: UInt16 = 0) -> Keymap.KeyPress {
        Keymap.KeyPress(keyCode: keyCode, character: character, modifiers: modifiers)
    }

    /// A form with text fields unless `text` says otherwise: a list or a select-only modal.
    private static func context(
        _ focus: ModalKeyContext.Focus? = .line,
        fields: Int = 3,
        text: Bool = true,
        submitting: Bool = false,
        submits: Bool = true
    ) -> ModalKeyContext {
        ModalKeyContext(focus: focus, fieldCount: fields, hasTextFields: text, submitting: submitting, submits: submits)
    }

    private static func returnSubmitsFromALineAndASelect() {
        let enter = press("\r", keyCode: 36)
        expect(ModalKeys.command(for: enter, in: context(.line)) == .submit, "Return should submit from a line")
        expect(ModalKeys.command(for: enter, in: context(.select)) == .submit, "Return should submit from a select")
        expect(ModalKeys.command(for: press(nil, keyCode: 76), in: context(.line)) == .submit, "keypad Enter should submit")
        expect(ModalKeys.command(for: press("\r", [.shift], keyCode: 36), in: context(.line)) == nil, "⇧Return should not submit")
        expect(ModalKeys.command(for: press("\r", [.control], keyCode: 36), in: context(.line)) == nil, "⌃Return should not submit")
    }

    private static func returnIsThePromptsOwnAndCommandReturnSubmitsFromAnywhere() {
        let enter = press("\r", keyCode: 36)
        let prompt = context(.prompt)
        expect(ModalKeys.command(for: enter, in: prompt) == nil, "the prompt's editor creates on Return, so the modal passes it")
        expect(ModalKeys.command(for: press("\r", [.shift], keyCode: 36), in: prompt) == nil, "⇧Return is the prompt's newline")
        expect(ModalKeys.command(for: press("\r", [.command], keyCode: 36), in: prompt) == .submit, "⌘Return should submit from the prompt")
        expect(ModalKeys.command(for: press("\r", [.command], keyCode: 36), in: context(.line)) == .submit, "⌘Return should submit from a line")
        expect(ModalKeys.command(for: press("\r", [.command], keyCode: 36), in: context(.select)) == .submit, "⌘Return should submit from a select")
        expect(ModalKeys.command(for: press("\r", [.command], keyCode: 36), in: context(nil, fields: 0)) == .submit, "⌘Return should confirm with no field")
    }

    private static func settingsSubmitsNothing() {
        let settings = context(.select, fields: 4, text: false, submits: false)
        expect(ModalKeys.command(for: press("\r", keyCode: 36), in: settings) == nil, "Settings' Return should do nothing")
        expect(ModalKeys.command(for: press("\r", [.command], keyCode: 36), in: settings) == nil, "Settings' ⌘Return should do nothing")
        expect(ModalKeys.command(for: press(nil, keyCode: 53), in: settings) == .cancel, "Settings should still close on Esc")
    }

    private static func escAndControlBracketCancel() {
        let controlBracket = press("[", [.control], keyCode: 33)
        for focus in [ModalKeyContext.Focus.line, .select, .prompt, nil] {
            let modal = context(focus, fields: focus == nil ? 0 : 3)
            expect(ModalKeys.command(for: press(nil, keyCode: 53), in: modal) == .cancel, "Esc should cancel \(String(describing: focus))")
            expect(ModalKeys.command(for: controlBracket, in: modal) == .cancel, "⌃[ should cancel \(String(describing: focus))")
        }
        expect(ModalKeys.command(for: press(nil, [.command], keyCode: 53), in: context()) == nil, "⌘Esc should not cancel")
    }

    private static func submitInFlightHoldsEveryKeyButEsc() {
        let inFlight = context(.line, submitting: true)
        expect(ModalKeys.command(for: press(nil, keyCode: 53), in: inFlight) == .cancel, "Esc should still close while a submit is in flight")
        expect(ModalKeys.command(for: press("[", [.control], keyCode: 33), in: inFlight) == .cancel, "⌃[ should still close while a submit is in flight")
        expect(ModalKeys.command(for: press("\r", keyCode: 36), in: inFlight) == .consume, "Return should be held while a submit is in flight")
        expect(ModalKeys.command(for: press(nil, keyCode: 48), in: inFlight) == .consume, "Tab should be held while a submit is in flight")
        expect(ModalKeys.command(for: press("a"), in: inFlight) == .consume, "typing should be held while a submit is in flight")
        expect(ModalKeys.command(for: press("J", [.command, .shift], keyCode: 38), in: inFlight) == .consume, "⇧⌘J should be held while a submit is in flight")
    }

    private static func tabAndBackTabMoveBetweenFields() {
        let form = context(.line, fields: 3)
        expect(ModalKeys.command(for: press(nil, keyCode: 48), in: form) == .nextField, "Tab should move to the next field")
        expect(ModalKeys.command(for: press(nil, [.shift], keyCode: 48), in: form) == .previousField, "⇧Tab should move back")
        expect(ModalKeys.command(for: press("j", [.control], keyCode: 38), in: form) == .nextField, "⌃j should move to the next field")
        expect(ModalKeys.command(for: press("k", [.control], keyCode: 40), in: form) == .previousField, "⌃k should move back")
        expect(ModalKeys.command(for: press("J", [.command, .shift], keyCode: 38), in: form) == .nextField, "⇧⌘J should move to the next field")
        expect(ModalKeys.command(for: press("K", [.command, .shift], keyCode: 40), in: form) == .previousField, "⇧⌘K should move back")
    }

    private static func tabWithOneFieldOrNoFieldDoesNothing() {
        let editRepo = context(.select, fields: 1, text: false)
        expect(ModalKeys.command(for: press(nil, keyCode: 48), in: editRepo) == .consume, "Tab with one field should be taken and do nothing")
        expect(ModalKeys.command(for: press(nil, [.shift], keyCode: 48), in: editRepo) == .consume, "⇧Tab with one field should be taken and do nothing")
        expect(ModalKeys.command(for: press("j", [.control], keyCode: 38), in: editRepo) == .consume, "⌃j with one field should be taken and do nothing")
        expect(ModalKeys.command(for: press("J", [.command, .shift], keyCode: 38), in: editRepo) == .consume, "⇧⌘J with one field should be taken and do nothing")
        let confirmation = context(nil, fields: 0, text: false)
        expect(ModalKeys.command(for: press(nil, keyCode: 48), in: confirmation) == .consume, "Tab with no field should be taken and do nothing")
    }

    private static func promptKeepsTabAsText() {
        let prompt = context(.prompt)
        expect(ModalKeys.command(for: press(nil, keyCode: 48), in: prompt) == nil, "Tab should type a tab in the prompt")
        expect(ModalKeys.command(for: press(nil, [.shift], keyCode: 48), in: prompt) == .previousField, "⇧Tab should move back from the prompt")
    }

    private static func arrowsAndHLCycleASelect() {
        let select = context(.select)
        expect(ModalKeys.command(for: press(nil, keyCode: 123), in: select) == .cycle(-1), "← should cycle a select back")
        expect(ModalKeys.command(for: press(nil, keyCode: 124), in: select) == .cycle(1), "→ should cycle a select forward")
        expect(ModalKeys.command(for: press("h", keyCode: 4), in: select) == .cycle(-1), "h should cycle a select back")
        expect(ModalKeys.command(for: press("l", keyCode: 37), in: select) == .cycle(1), "l should cycle a select forward")
        expect(ModalKeys.command(for: press("H", [.command, .shift], keyCode: 4), in: select) == .cycle(-1), "⇧⌘H should cycle a select back")
        expect(ModalKeys.command(for: press("L", [.command, .shift], keyCode: 37), in: select) == .cycle(1), "⇧⌘L should cycle a select forward")
        expect(ModalKeys.cycleStep(press(nil, keyCode: 123)) == -1 && ModalKeys.cycleStep(press("l", keyCode: 37)) == 1, "the cycle step should follow the arrow and letter keys")
        expect(ModalKeys.cycleStep(press("a")) == nil, "a letter is no cycle step")
    }

    private static func cyclingIsOnlyForSelects() {
        for focus in [ModalKeyContext.Focus.line, .prompt] {
            let modal = context(focus)
            expect(ModalKeys.command(for: press(nil, keyCode: 123), in: modal) == nil, "← should not cycle \(focus): the text takes the caret")
            expect(ModalKeys.command(for: press("h", keyCode: 4), in: modal) == nil, "h should be typed into \(focus)")
            expect(ModalKeys.command(for: press("H", [.command, .shift], keyCode: 4), in: modal) == .consume, "⇧⌘H is the modal's, so it is taken even with nothing to cycle")
        }
    }

    private static func plainLettersBelongToTheText() {
        expect(ModalKeys.command(for: press("a"), in: context(.line)) == nil, "a letter should be typed into a line")
        expect(ModalKeys.command(for: press("b"), in: context(.select)) == nil, "a letter is the picker's to start a search with, not the modal's")
        expect(ModalKeys.command(for: press(nil, keyCode: 51), in: context(.line)) == nil, "Delete should reach the text")
    }

    private static func editRepoAndDeleteConfirmationSubmit() {
        let editRepo = context(.select, fields: 1, text: false)
        expect(ModalKeys.command(for: press("\r", keyCode: 36), in: editRepo) == .submit, "Edit Repo's Return should submit")
        let confirmation = context(nil, fields: 0, text: false)
        expect(ModalKeys.command(for: press("\r", keyCode: 36), in: confirmation) == .submit, "the delete confirmation's Return should confirm")
        expect(ModalKeys.command(for: press(nil, keyCode: 53), in: confirmation) == .cancel, "the delete confirmation's Esc should cancel")
        expect(ModalKeys.command(for: press("a"), in: confirmation) == nil, "typing should pass the confirmation by")
    }

    private static func tabAndControlJKMoveFromASelectInAFormWithTextFields() {
        let form = context(.select, fields: 3, text: true)
        expect(ModalKeys.command(for: press(nil, keyCode: 48), in: form) == .nextField, "Tab should move on from a select in a form with text fields")
        expect(ModalKeys.command(for: press(nil, [.shift], keyCode: 48), in: form) == .previousField, "⇧Tab should move back from a select in a form with text fields")
        expect(ModalKeys.command(for: press("j", [.control], keyCode: 38), in: form) == .nextField, "⌃J should move on from a select in a form with text fields")
        expect(ModalKeys.command(for: press("k", [.control], keyCode: 40), in: form) == .previousField, "⌃K should move back from a select in a form with text fields")
    }

    /// The letters belong to the text: a field types them, and a select in a form passes them on (a picker starts its
    /// search with them), so a form's j and k never move.
    private static func jAndKTypeInAFormWithTextFields() {
        for focus in [ModalKeyContext.Focus.line, .prompt, .select] {
            let form = context(focus, fields: 3, text: true)
            expect(ModalKeys.command(for: press("j", keyCode: 38), in: form) == nil, "j should type in a form with text fields, focus \(focus)")
            expect(ModalKeys.command(for: press("k", keyCode: 40), in: form) == nil, "k should type in a form with text fields, focus \(focus)")
        }
        let colourSearch = context(.line, fields: 1, text: false)
        expect(ModalKeys.command(for: press("j", keyCode: 38), in: colourSearch) == nil, "j should type into a colour's search, which is a line even in a modal with no text field")
    }

    private static func jAndKMoveAListOrASelectOnlyModal() {
        for modal in [context(nil, fields: 3, text: false), context(.select, fields: 4, text: false)] {
            expect(ModalKeys.command(for: press("j", keyCode: 38), in: modal) == .nextField, "j should move down a list or a select-only modal")
            expect(ModalKeys.command(for: press("k", keyCode: 40), in: modal) == .previousField, "k should move up a list or a select-only modal")
            expect(ModalKeys.command(for: press("J", [.command, .shift], keyCode: 38), in: modal) == .nextField, "⇧⌘J should move down a list or a select-only modal")
            expect(ModalKeys.command(for: press("K", [.command, .shift], keyCode: 40), in: modal) == .previousField, "⇧⌘K should move up a list or a select-only modal")
        }
        expect(ModalKeys.command(for: press("j", keyCode: 38), in: context(nil, fields: 1, text: false)) == .consume, "j with one row has nowhere to go and is taken")
        expect(ModalKeys.command(for: press("j", keyCode: 38), in: context(nil, fields: 0, text: false)) == .consume, "j with no rows is taken")
    }

    private static func tabAndControlJKTakeNothingInAListOrASelectOnlyModal() {
        for modal in [context(nil, fields: 3, text: false), context(.select, fields: 4, text: false)] {
            expect(ModalKeys.command(for: press(nil, keyCode: 48), in: modal) == .consume, "Tab should take the press and do nothing in a list or a select-only modal")
            expect(ModalKeys.command(for: press(nil, [.shift], keyCode: 48), in: modal) == .consume, "⇧Tab should take the press and do nothing in a list or a select-only modal")
            expect(ModalKeys.command(for: press("j", [.control], keyCode: 38), in: modal) == .consume, "⌃J should take the press and do nothing in a list or a select-only modal")
            expect(ModalKeys.command(for: press("k", [.control], keyCode: 40), in: modal) == .consume, "⌃K should take the press and do nothing in a list or a select-only modal")
        }
    }

    /// ↑ and ↓ never move a modal. A text field's caret takes them; anywhere else they are taken and do nothing.
    private static func arrowsNeverMoveAModal() {
        for modal in [context(nil, fields: 3, text: false), context(.select, fields: 4, text: false), context(.select, fields: 4, text: true)] {
            expect(ModalKeys.command(for: press(nil, keyCode: 126), in: modal) == .consume, "↑ should be taken and do nothing in a modal with no text field caret")
            expect(ModalKeys.command(for: press(nil, keyCode: 125), in: modal) == .consume, "↓ should be taken and do nothing in a modal with no text field caret")
        }
        for focus in [ModalKeyContext.Focus.line, .prompt] {
            let field = context(focus, fields: 3, text: true)
            expect(ModalKeys.command(for: press(nil, keyCode: 126), in: field) == nil, "↑ should reach the caret of \(focus)")
            expect(ModalKeys.command(for: press(nil, keyCode: 125), in: field) == nil, "↓ should reach the caret of \(focus)")
        }
        expect(ModalKeys.command(for: press(nil, [.option], keyCode: 126), in: context(nil, fields: 3, text: false)) == nil, "⌥↑ is not a modal key and passes")
    }

    /// ⌥k is no field key, in a form or a list: the stray alias was removed.
    private static func theRemovedOptionKAliasIsNoFieldKey() {
        expect(ModalKeys.command(for: press(nil, [.option], keyCode: 40), in: context(.line, fields: 3, text: true)) == nil, "⌥k in a form should pass, not step a field")
        expect(ModalKeys.command(for: press(nil, [.option], keyCode: 40), in: context(nil, fields: 3, text: false)) == nil, "⌥k in a list should pass, not step a row")
    }

    /// The rule per modal, as the sheets build their contexts. Each row: the context, what Tab does, what j does and
    /// what ↑ does. Nil is "the press goes on to the text" (typed letters, the caret).
    private static func everyModalsMovementKeys() {
        let tab = press(nil, keyCode: 48)
        let j = press("j", keyCode: 38)
        let up = press(nil, keyCode: 126)
        let modals: [(name: String, context: ModalKeyContext, tab: ModalCommand?, j: ModalCommand?, up: ModalCommand?)] = [
            ("Settings' Models", context(.select, fields: 4, text: false, submits: false), .consume, .nextField, .consume),
            ("Settings' Projects", context(nil, fields: 5, text: false), .consume, .nextField, .consume),
            ("Add or Edit Project, name", context(.line, fields: 3, text: true), .nextField, nil, nil),
            ("Add or Edit Project, colour select", context(.select, fields: 3, text: true), .nextField, nil, .consume),
            ("New Session, path", context(.line, fields: 5, text: true), .nextField, nil, nil),
            ("New Session, agent select", context(.select, fields: 5, text: true), .nextField, nil, .consume),
            ("New Quest, prompt", context(.prompt, fields: 2, text: true), nil, nil, nil),
            ("New Quest, project", context(.line, fields: 2, text: true), .nextField, nil, nil),
            ("Edit Session, title", context(.line, fields: 2, text: true), .nextField, nil, nil),
            ("Edit Repo, colour select", context(.select, fields: 1, text: false), .consume, .consume, .consume),
            ("Edit Repo, colour search", context(.line, fields: 1, text: false), .consume, nil, nil),
            ("delete confirmation", context(nil, fields: 0, text: false), .consume, .consume, .consume),
            ("Quest Log list", context(nil, fields: 4, text: false), .consume, .nextField, .consume),
            ("Quest Log filter", context(.line, fields: 1, text: true), .consume, nil, nil),
        ]
        for modal in modals {
            expect(ModalKeys.command(for: tab, in: modal.context) == modal.tab, "Tab in \(modal.name)")
            expect(ModalKeys.command(for: j, in: modal.context) == modal.j, "j in \(modal.name)")
            expect(ModalKeys.command(for: up, in: modal.context) == modal.up, "↑ in \(modal.name)")
        }
    }
}
