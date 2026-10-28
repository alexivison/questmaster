import Foundation
import QuestmasterCore

struct ColorFieldTests {
    static func run() {
        startsOnTheSelectedColourWithNoneFirst()
        typingFiltersTheNames()
        movingPreviewsAndScrollsTheList()
        typingRanksAndHighlightsTheBestMatch()
        browsingTheStartingTextHighlightsTheCurrentColour()
        pickingSelectsAndReturnsToSelect()
        cyclingWrapsWithoutTheList()
        endingASearchRestoresTheName()
        cycleKeysAreTheColoursOwn()
        sharedPickerCommandsApplyToTheColour()
        savingMidSearchTakesTheHighlightedColour()
        pickerListWindowFollowsTheHighlight()
        caretFollowsTheModeOnlyWhileFocused()
        pathRowsDontFallBackToRecentsForATypedPath()
        suggestionListRemembersAMovedHighlight()
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
        expect(model.matches == ["violet"], "a whole name should filter to that colour")
        model.type("zzz")
        expect(model.matches.isEmpty && !model.showsSuggestions, "no match should show no list")
    }

    private static func movingPreviewsAndScrollsTheList() {
        var model = ColorFieldModel(colors: ["", "blue", "green", "yellow", "red"], selected: "blue")
        model.startSearch(.editCurrent)
        expect(model.showsSuggestions && model.highlightedColor == "blue", "editing should open the list on the selected colour")
        expect(model.visibleMatches == ["blue", "green", "yellow"], "the list should show three rows from the selection")
        expect(model.swatchColor == "blue", "browsing should highlight, and show, the selection")
        model.moveHighlight(1)
        model.moveHighlight(1)
        model.moveHighlight(1)
        expect(model.highlightedColor == "red" && model.swatchColor == "red", "the swatch should preview the highlighted colour")
        expect(model.visibleMatches == ["green", "yellow", "red"] && model.visibleHighlightIndex == 2, "the list should scroll to keep the highlight in view")
        model.moveHighlight(1)
        expect(model.highlightedColor == "" && model.visibleMatches == ["", "blue", "green"], "moving past the last colour should wrap to none at the top")
        expect(model.selectedColor == "blue", "moving should not change the selection")
    }

    private static func typingRanksAndHighlightsTheBestMatch() {
        var model = ColorFieldModel(selected: "orange")
        model.startSearch(.seed("r"))
        model.type("red")
        expect(model.matches.first == "red" && model.highlightedColor == "red", "red should come first and be highlighted")
        expect(model.swatchColor == "red", "the swatch should preview the best match")
        model.type("re")
        expect(model.matches == ["red", "green"], "re should list the prefix match, then the ones containing it: \(model.matches)")
        model.type("o")
        expect(model.matches == ["orange", NewSessionFormModel.noColor, "yellow", "gold", "indigo", "violet"], "prefix matches should come before the rest, in palette order: \(model.matches)")
        expect(model.highlightedColor == "orange", "the best match should be highlighted")
    }

    private static func browsingTheStartingTextHighlightsTheCurrentColour() {
        var model = ColorFieldModel(selected: "teal")
        model.startSearch(.editCurrent)
        expect(model.matches == model.colors, "editing the name should browse every colour")
        expect(model.highlightedColor == "teal" && model.visibleMatches.contains("teal"), "browsing should highlight the current colour")
        model.type("")
        expect(model.highlightedColor == "teal", "an emptied search should browse from the current colour")
        model.type("teal")
        expect(model.highlightedColor == "teal" && model.matches == model.colors, "retyping the starting text should browse again")
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
        expect(model.visibleMatches == ["teal", "sky", "indigo"], "an emptied search should browse from the current colour")
        model.pick(visibleRow: 1)
        expect(model.selectedColor == "sky", "a click should pick that row")
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

    /// ←/→ cycle in SELECT, ⌥←/⌥→ in both states; the rest of the colour's keys are the shared picker's.
    private static func cycleKeysAreTheColoursOwn() {
        expect(ColorFieldModel.cycleDelta(keyCode: 123, modifiers: [], mode: .select) == -1 && ColorFieldModel.cycleDelta(keyCode: 124, modifiers: [], mode: .select) == 1, "←/→ should cycle in SELECT")
        expect(ColorFieldModel.cycleDelta(keyCode: 123, modifiers: [.option], mode: .select) == -1 && ColorFieldModel.cycleDelta(keyCode: 124, modifiers: [.option], mode: .search) == 1, "⌥←/⌥→ should cycle in both states")
        expect(ColorFieldModel.cycleDelta(keyCode: 123, modifiers: [], mode: .search) == nil, "plain ← should move the caret while searching")
        expect(ColorFieldModel.cycleDelta(keyCode: 124, modifiers: [.command], mode: .select) == nil, "⌘ keys should not cycle")
    }

    /// The shared commands move the colour through its own model: a search previews the highlight, Tab or
    /// Return picks it, and Esc shows the selected colour again.
    private static func sharedPickerCommandsApplyToTheColour() {
        var model = ColorFieldModel(colors: ["", "blue", "green", "yellow", "red"], selected: "blue")
        model.apply(.startSearch(.editCurrent))
        expect(model.showsSuggestions && model.highlightedColor == "blue", "startSearch should open the list on the selection")
        model.apply(.moveHighlight(1))
        expect(model.highlightedColor == "green" && model.swatchColor == "green", "moveHighlight should move and preview the highlight")
        model.apply(.pick)
        expect(model.selectedColor == "green" && model.mode == .select, "pick should select the highlighted colour")
        model.apply(.startSearch(.seed("y")))
        model.apply(.restore)
        expect(model.selectedColor == "green" && model.text == "green" && model.mode == .select, "restore should show the selected colour again")
    }

    private static func savingMidSearchTakesTheHighlightedColour() {
        var model = ColorFieldModel(selected: "blue")
        model.startSearch(.seed("red"))
        expect(model.swatchColor == "red" && model.selectedColor == "blue", "precondition: the swatch previews red over the saved blue")
        model.commitPendingPick()
        expect(model.selectedColor == "red" && model.mode == .select, "saving mid-search should take the previewed colour")
        model.commitPendingPick()
        expect(model.selectedColor == "red", "with no search, saving keeps the selection")
        var unmatched = ColorFieldModel(selected: "blue")
        unmatched.startSearch(.seed("zzz"))
        unmatched.commitPendingPick()
        expect(unmatched.selectedColor == "blue", "a search with no match keeps the selection")
    }

    private static func pickerListWindowFollowsTheHighlight() {
        var window = PickerListWindow(visibleRows: 3)
        let items = Array(0..<6)
        window.reset(highlighting: 5, count: items.count)
        expect(window.visible(items) == [3, 4, 5] && window.visibleHighlightIndex == 2 && !window.moved, "a highlight near the end should show the last full screen")
        window.move(1, count: items.count)
        expect(window.highlighted(items) == 0 && window.visible(items) == [0, 1, 2] && window.moved, "moving past the end should wrap to the top")
        window.move(-1, count: items.count)
        expect(window.highlighted(items) == 5 && window.visible(items) == [3, 4, 5], "moving up from the top should wrap to the end")
        window.reset(highlighting: 9, count: 2)
        expect(window.highlightedIndex == 1, "a reset should clamp to the list")
    }

    private static func caretFollowsTheModeOnlyWhileFocused() {
        expect(PickerFieldMode.caretChange(from: .select, to: .search, fieldFocused: true) == .intoText, "a search should put the caret in the text")
        expect(PickerFieldMode.caretChange(from: .search, to: .select, fieldFocused: true) == .outOfText, "SELECT should take the caret out")
        expect(PickerFieldMode.caretChange(from: .search, to: .select, fieldFocused: false) == nil, "a search ended by leaving should leave the caret where focus went")
        expect(PickerFieldMode.caretChange(from: .search, to: .search, fieldFocused: true) == nil, "no mode change moves no caret")
    }

    private static func pathRowsDontFallBackToRecentsForATypedPath() {
        let recents = ["/r/one", "/r/two"]
        expect(SuggestionList.pathRows(suggestions: [], recents: recents, query: "/tmp/nope", recentsOnly: false, maxRows: 3) == ["/tmp/nope"], "a typed path with no suggestions should offer itself, not recents")
        expect(SuggestionList.pathRows(suggestions: [], recents: recents, query: "", recentsOnly: false, maxRows: 3) == recents, "an empty path should offer the recents")
        expect(SuggestionList.pathRows(suggestions: ["/a"], recents: recents, query: "/a", recentsOnly: true, maxRows: 3) == recents, "⌃r should offer the recents")
        expect(SuggestionList.pathRows(suggestions: ["/a", "/b", "/c", "/d"], recents: [], query: "/", recentsOnly: false, maxRows: 3) == ["/a", "/b", "/c"], "at most three rows")
    }

    private static func suggestionListRemembersAMovedHighlight() {
        var list = SuggestionList()
        list.show(["/a", "/b"])
        expect(!list.moved, "fresh rows have no moved highlight: Return keeps the typed path")
        list.moveHighlight(1)
        expect(list.moved && list.highlighted == "/b", "↓ should mark the highlight as chosen")
        list.show(["/c"])
        expect(!list.moved, "new rows should forget the move")
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
