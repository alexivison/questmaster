import Foundation
import QuestmasterCore

/// The keys the Quest Log's and the artifact dock's filter fields share (`FilterFieldKey`).
struct FilterFieldKeyTests {
    static func run() {
        suggestionKeysMoveTheHighlightWhileSuggestionsShow()
        listKeysMoveTheListWhenNoSuggestionShows()
        lettersTypeAndNeverMoveTheList()
        tabTakesOnlyAShownSuggestion()
        returnTakesASuggestionOrReturnsToTheList()
        backspaceRemovesTheLastChipOnlyFromAnEmptyField()
        escHidesSuggestionsThenLeaves()
        otherModifiedKeysBelongToTheText()
        print("FilterFieldKeyTests: all tests passed")
    }

    private static func suggestionKeysMoveTheHighlightWhileSuggestionsShow() {
        expect(key("", 126, showsSuggestions: true) == .moveSuggestion(-1), "↑ should move the highlight up")
        expect(key("", 125, showsSuggestions: true) == .moveSuggestion(1), "↓ should move the highlight down")
        expect(key("p", 35, modifiers: [.control], showsSuggestions: true) == .moveSuggestion(-1), "⌃p should move the highlight up")
        expect(key("n", 45, modifiers: [.control], showsSuggestions: true) == .moveSuggestion(1), "⌃n should move the highlight down")
    }

    private static func listKeysMoveTheListWhenNoSuggestionShows() {
        expect(key("", 126, showsSuggestions: false) == .moveList(-1), "↑ with no suggestion should move the list up")
        expect(key("", 125, showsSuggestions: false) == .moveList(1), "↓ with no suggestion should move the list down")
        expect(key("p", 35, modifiers: [.control], showsSuggestions: false) == .moveList(-1), "⌃p with no suggestion should move the list up")
        expect(key("n", 45, modifiers: [.control], showsSuggestions: false) == .moveList(1), "⌃n with no suggestion should move the list down")
    }

    /// `j`, `k` and `l` are the list's keys elsewhere; the filter types them.
    private static func lettersTypeAndNeverMoveTheList() {
        expect(key("j", 38, showsSuggestions: false) == nil, "j should type into the filter")
        expect(key("k", 40, showsSuggestions: true) == nil, "k should type into the filter")
        expect(key("l", 37, showsSuggestions: false) == nil, "l should type into the filter, not open")
        expect(key("n", 45, showsSuggestions: true) == nil, "a plain n should type")
        expect(key("j", 38, modifiers: [.control], showsSuggestions: false) == nil, "⌃j is not a list key here")
    }

    private static func tabTakesOnlyAShownSuggestion() {
        expect(key("\t", 48, showsSuggestions: true) == .acceptSuggestion, "Tab should take the highlighted suggestion")
        expect(key("\t", 48, showsSuggestions: false) == nil, "Tab with no suggestion should be the text system's")
        expect(key("\t", 48, modifiers: [.shift], showsSuggestions: true) == nil, "⇧Tab should be the text system's")
    }

    private static func returnTakesASuggestionOrReturnsToTheList() {
        expect(key("\r", 36, showsSuggestions: true) == .acceptSuggestion, "Return should take the highlighted suggestion")
        expect(key("\r", 36, showsSuggestions: false) == .returnToList, "Return with no suggestion should return to the list")
        expect(key("\r", 76, showsSuggestions: false) == .returnToList, "the keypad Return should return to the list too")
        expect(key("\r", 36, modifiers: [.command], showsSuggestions: false) == .returnToList, "⌘Return should return to the list too")
        expect(key("\r", 36, modifiers: [.shift], showsSuggestions: false) == nil, "⇧Return should be the text system's")
    }

    private static func backspaceRemovesTheLastChipOnlyFromAnEmptyField() {
        expect(key(nil, 51, queryIsEmpty: true, hasChips: true) == .removeLastChip, "Backspace in an empty field should remove the last chip")
        expect(key(nil, 51, queryIsEmpty: false, hasChips: true) == nil, "Backspace in a field with text should delete a character")
        expect(key(nil, 51, queryIsEmpty: true, hasChips: false) == nil, "Backspace with no chip should do nothing")
    }

    private static func escHidesSuggestionsThenLeaves() {
        expect(key("\u{1b}", 53, showsSuggestions: true) == .hideSuggestions, "Esc should hide the suggestions first")
        expect(key("\u{1b}", 53, showsSuggestions: false) == .leave, "Esc with no suggestion should leave the filter")
        expect(key("[", 33, modifiers: [.control], showsSuggestions: true) == .hideSuggestions, "⌃[ should hide the suggestions first")
        expect(key("[", 33, modifiers: [.control], showsSuggestions: false) == .leave, "⌃[ with no suggestion should leave the filter")
    }

    private static func otherModifiedKeysBelongToTheText() {
        expect(key("", 126, modifiers: [.option], showsSuggestions: true) == nil, "⌥↑ should be the text system's")
        expect(key("", 126, modifiers: [.command], showsSuggestions: false) == nil, "⌘↑ should be the text system's")
        expect(key("", 125, modifiers: [.shift], showsSuggestions: false) == nil, "⇧↓ should be the text system's")
    }

    /// The key the filter resolves for one press.
    private static func key(
        _ characters: String?,
        _ keyCode: UInt16,
        modifiers: Set<Keymap.Modifier> = [],
        showsSuggestions: Bool = false,
        queryIsEmpty: Bool = false,
        hasChips: Bool = true
    ) -> FilterFieldCommand? {
        FilterFieldKey.command(
            Keymap.KeyPress(keyCode: keyCode, character: characters, modifiers: modifiers),
            showsSuggestions: showsSuggestions,
            queryIsEmpty: queryIsEmpty,
            hasChips: hasChips
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fail(message)
        }
    }

    private static func fail(_ message: String) -> Never {
        fputs("FilterFieldKeyTests failed: \(message)\n", stderr)
        Foundation.exit(1)
    }
}
