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
        promptKeepsTabOnlyWhereItSaysSo()
        arrowsAndHLCycleASelect()
        cyclingIsOnlyForSelects()
        plainLettersBelongToTheText()
        editRepoAndDeleteConfirmationSubmit()
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

    private static func context(
        _ focus: ModalKeyContext.Focus? = .line,
        fields: Int = 3,
        submitting: Bool = false,
        submits: Bool = true
    ) -> ModalKeyContext {
        ModalKeyContext(focus: focus, fieldCount: fields, submitting: submitting, submits: submits)
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
        for keepsTab in [true, false] {
            let prompt = context(.prompt(keepsTab: keepsTab))
            expect(ModalKeys.command(for: enter, in: prompt) == nil, "the prompt's editor creates on Return, so the modal passes it")
            expect(ModalKeys.command(for: press("\r", [.shift], keyCode: 36), in: prompt) == nil, "⇧Return is the prompt's newline")
            expect(ModalKeys.command(for: press("\r", [.command], keyCode: 36), in: prompt) == .submit, "⌘Return should submit from the prompt")
        }
        expect(ModalKeys.command(for: press("\r", [.command], keyCode: 36), in: context(.line)) == .submit, "⌘Return should submit from a line")
        expect(ModalKeys.command(for: press("\r", [.command], keyCode: 36), in: context(.select)) == .submit, "⌘Return should submit from a select")
        expect(ModalKeys.command(for: press("\r", [.command], keyCode: 36), in: context(nil, fields: 0)) == .submit, "⌘Return should confirm with no field")
    }

    private static func settingsSubmitsNothing() {
        let settings = context(.select, fields: 4, submits: false)
        expect(ModalKeys.command(for: press("\r", keyCode: 36), in: settings) == nil, "Settings' Return should do nothing")
        expect(ModalKeys.command(for: press("\r", [.command], keyCode: 36), in: settings) == nil, "Settings' ⌘Return should do nothing")
        expect(ModalKeys.command(for: press(nil, keyCode: 53), in: settings) == .cancel, "Settings should still close on Esc")
    }

    private static func escAndControlBracketCancel() {
        let controlBracket = press("[", [.control], keyCode: 33)
        for focus in [ModalKeyContext.Focus.line, .select, .prompt(keepsTab: true), nil] {
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
        expect(ModalKeys.command(for: press(nil, [.option], keyCode: 40), in: form) == .nextField, "⌥k should move to the next field")
        expect(ModalKeys.command(for: press("k", [.control], keyCode: 40), in: form) == .previousField, "⌃k should move back")
        expect(ModalKeys.command(for: press("J", [.command, .shift], keyCode: 38), in: form) == .nextField, "⇧⌘J should move to the next field")
        expect(ModalKeys.command(for: press("K", [.command, .shift], keyCode: 40), in: form) == .previousField, "⇧⌘K should move back")
    }

    private static func tabWithOneFieldOrNoFieldDoesNothing() {
        let editRepo = context(.select, fields: 1)
        expect(ModalKeys.command(for: press(nil, keyCode: 48), in: editRepo) == .consume, "Tab with one field should be taken and do nothing")
        expect(ModalKeys.command(for: press(nil, [.shift], keyCode: 48), in: editRepo) == .consume, "⇧Tab with one field should be taken and do nothing")
        expect(ModalKeys.command(for: press("j", [.control], keyCode: 38), in: editRepo) == .consume, "⌃j with one field should be taken and do nothing")
        expect(ModalKeys.command(for: press("J", [.command, .shift], keyCode: 38), in: editRepo) == .consume, "⇧⌘J with one field should be taken and do nothing")
        let confirmation = context(nil, fields: 0)
        expect(ModalKeys.command(for: press(nil, keyCode: 48), in: confirmation) == .consume, "Tab with no field should be taken and do nothing")
    }

    private static func promptKeepsTabOnlyWhereItSaysSo() {
        let keeps = context(.prompt(keepsTab: true))
        expect(ModalKeys.command(for: press(nil, keyCode: 48), in: keeps) == nil, "a prompt that keeps Tab should type it")
        expect(ModalKeys.command(for: press(nil, [.shift], keyCode: 48), in: keeps) == .previousField, "⇧Tab should move back from a prompt that keeps Tab")
        let moves = context(.prompt(keepsTab: false))
        expect(ModalKeys.command(for: press(nil, keyCode: 48), in: moves) == .nextField, "a prompt that doesn't keep Tab should move on with it")
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
        for focus in [ModalKeyContext.Focus.line, .prompt(keepsTab: true)] {
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
        let editRepo = context(.select, fields: 1)
        expect(ModalKeys.command(for: press("\r", keyCode: 36), in: editRepo) == .submit, "Edit Repo's Return should submit")
        let confirmation = context(nil, fields: 0)
        expect(ModalKeys.command(for: press("\r", keyCode: 36), in: confirmation) == .submit, "the delete confirmation's Return should confirm")
        expect(ModalKeys.command(for: press(nil, keyCode: 53), in: confirmation) == .cancel, "the delete confirmation's Esc should cancel")
        expect(ModalKeys.command(for: press("a"), in: confirmation) == nil, "typing should pass the confirmation by")
    }
}
