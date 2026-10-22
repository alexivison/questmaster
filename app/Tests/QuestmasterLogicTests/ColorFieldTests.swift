import Foundation
import QuestmasterCore

struct ColorFieldTests {
    static func run() {
        startsOnTheSelectedColourWithNoneFirst()
        typingFiltersTheNames()
        movingPreviewsAndScrollsTheList()
        pickingSelectsAndReturnsToSelect()
        cyclingWrapsWithoutTheList()
        endingASearchRestoresTheName()
        selectKeysCycleAndPrintableKeysSearch()
        searchKeysMoveAndPick()
        searchStartIsPrintableTextBackspaceOrReturn()
        print("ColorFieldTests: all tests passed")
    }

    private static func startsOnTheSelectedColourWithNoneFirst() {
        let model = ColorFieldModel(selected: " Orange ")
        expect(model.colors.first == NewSessionFormModel.noColor, "no colour should be the first option")
        expect(model.colors == NewSessionFormModel.defaultColors, "the colours should be the palette's own list")
        expect(model.selectedColor == "orange" && model.text == "orange", "the field should start on the colour's name, lowercase")
        expect(model.mode == .select && !model.showsSuggestions, "the field should start in SELECT with no list")
        let none = ColorFieldModel(selected: "")
        expect(none.selectedColor.isEmpty && none.text == "none", "no colour should read none")
        let unknown = ColorFieldModel(selected: "chartreuse")
        expect(unknown.selectedColor.isEmpty, "an unknown colour should fall back to none")
    }

    private static func typingFiltersTheNames() {
        var model = ColorFieldModel(selected: "orange")
        model.type("e")
        expect(model.mode == .search, "typing should search")
        expect(model.matches.contains(NewSessionFormModel.noColor) && model.matches.contains("blue") && !model.matches.contains("pink"), "typing should match names containing the text")
        model.type("TEA")
        expect(model.matches == ["teal"], "matching should ignore case")
        model.type("")
        expect(model.matches == model.colors, "an empty search should browse every colour")
        model.type("violet")
        expect(model.matches == model.colors, "a whole name should browse every colour")
        model.type("zzz")
        expect(model.matches.isEmpty && !model.showsSuggestions, "no match should show no list")
    }

    private static func movingPreviewsAndScrollsTheList() {
        var model = ColorFieldModel(colors: ["", "blue", "green", "yellow", "red"], selected: "blue")
        model.startSearch(.editCurrent)
        expect(model.showsSuggestions && model.highlightedColor == "blue", "editing should open the list on the selected colour")
        expect(model.visibleMatches == ["blue", "green", "yellow"], "the list should show three rows from the selection")
        expect(model.swatchColor == "blue" && !model.isPreviewing, "the swatch should show the selection until the highlight moves")
        model.moveHighlight(1)
        model.moveHighlight(1)
        model.moveHighlight(1)
        expect(model.highlightedColor == "red" && model.swatchColor == "red", "the swatch should preview the highlighted colour")
        expect(model.visibleMatches == ["green", "yellow", "red"] && model.visibleHighlightIndex == 2, "the list should scroll to keep the highlight in view")
        model.moveHighlight(1)
        expect(model.highlightedColor == "" && model.visibleMatches == ["", "blue", "green"], "moving past the last colour should wrap to none at the top")
        expect(model.selectedColor == "blue", "moving should not change the selection")
    }

    private static func pickingSelectsAndReturnsToSelect() {
        var model = ColorFieldModel(selected: "orange")
        model.startSearch(.seed("te"))
        expect(model.matches == ["teal"], "precondition: one match")
        expect(model.pick(), "the highlighted colour should be picked")
        expect(model.selectedColor == "teal" && model.text == "teal", "picking should select the colour and show its name")
        expect(model.mode == .select && !model.showsSuggestions, "picking should return to SELECT")
        expect(!model.pick(), "nothing should be picked with no list")
        model.startSearch(.seed(""))
        model.pick(visibleRow: 1)
        expect(model.selectedColor == "blue", "a click should pick that row")
    }

    private static func cyclingWrapsWithoutTheList() {
        var model = ColorFieldModel(selected: "")
        model.cycle(-1)
        expect(model.selectedColor == NewSessionFormModel.defaultColors.last, "cycling back from none should wrap to the last colour")
        model.cycle(1)
        model.cycle(1)
        expect(model.selectedColor == "blue" && model.mode == .select && !model.showsSuggestions, "cycling should move through the colours without the list")
    }

    private static func endingASearchRestoresTheName() {
        var model = ColorFieldModel(selected: "gold")
        model.startSearch(.seed("x"))
        model.endSearch()
        expect(model.text == "gold" && model.mode == .select && model.selectedColor == "gold", "Esc should restore the name and keep the colour")
    }

    private static func selectKeysCycleAndPrintableKeysSearch() {
        func command(_ characters: String, _ keyCode: UInt16, option: Bool = false, mode: PickerFieldMode = .select, list: Bool = false) -> ColorFieldCommand? {
            ColorFieldModel.command(keyCode: keyCode, characters: characters, command: false, control: false, option: option, mode: mode, showsSuggestions: list)
        }
        expect(command("", 123) == .cycle(-1) && command("", 124) == .cycle(1), "←/→ should cycle in SELECT")
        expect(command("h", 4) == .startSearch(.seed("h")), "h should start a search in SELECT")
        expect(command("", 123, option: true) == .cycle(-1) && command("", 124, option: true, mode: .search) == .cycle(1), "⌥←/⌥→ should cycle in both states")
        expect(command("", 123, mode: .search) == nil, "plain ← should move the caret while searching")
        expect(command("\r", 36) == .startSearch(.editCurrent) && command("", 51) == .startSearch(.editCurrent), "Return and Backspace should edit the name")
        expect(command("\t", 48) == nil && command("\u{1b}", 53) == nil, "Tab and Esc in SELECT should stay the sheet's")
        expect(ColorFieldModel.command(keyCode: 1, characters: "s", command: false, control: true, option: false, mode: .select, showsSuggestions: false) == nil, "⌃ keys should stay the sheet's")
    }

    private static func searchKeysMoveAndPick() {
        func command(_ characters: String, _ keyCode: UInt16, list: Bool) -> ColorFieldCommand? {
            ColorFieldModel.command(keyCode: keyCode, characters: characters, command: false, control: false, option: false, mode: .search, showsSuggestions: list)
        }
        expect(command("", 126, list: true) == .moveHighlight(-1) && command("", 125, list: false) == .moveHighlight(1), "↑/↓ should move while searching")
        expect(command("\t", 48, list: true) == .pick && command("\r", 36, list: true) == .pick, "Tab and Return should pick from the list")
        expect(command("\t", 48, list: false) == .endSearch, "Tab with no list should end the search")
        expect(command("\u{1b}", 53, list: true) == .endSearch, "Esc should end the search before the sheet closes")
        expect(command("a", 0, list: true) == nil, "letters should type while searching")
    }

    private static func searchStartIsPrintableTextBackspaceOrReturn() {
        func start(_ characters: String?, _ keyCode: UInt16, command: Bool = false, control: Bool = false, option: Bool = false) -> PickerFieldMode.SearchStart? {
            PickerFieldMode.searchStart(characters: characters, keyCode: keyCode, command: command, control: control, option: option)
        }
        expect(start("o", 31) == .seed("o") && start("O", 31) == .seed("O") && start(" ", 49) == .seed(" "), "printable keys should seed the search")
        expect(start(nil, 51) == .editCurrent && start("\r", 36) == .editCurrent && start("\u{3}", 76) == .editCurrent, "Backspace and Return should edit the current text")
        for (characters, keyCode) in [("\t", UInt16(48)), ("\u{1b}", 53), ("\u{F702}", 123), ("\u{F701}", 125)] {
            expect(start(characters, keyCode) == nil, "key \(keyCode) is not text")
        }
        expect(start("o", 31, command: true) == nil && start("o", 31, control: true) == nil && start("ø", 31, option: true) == nil, "modified keys should not search")
        expect(start("\u{F728}", 117) == nil, "function keys should not search")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fail(message)
        }
    }

    private static func fail(_ message: String) -> Never {
        fputs("ColorFieldTests failed: \(message)\n", stderr)
        Foundation.exit(1)
    }
}
