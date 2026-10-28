import Foundation
import QuestmasterCore

/// The keys the colour, model, project and path fields share (`PickerFieldKey`), and what the fields do with them.
struct PickerFieldKeyTests {
    static func run() {
        selectStartsASearchOnPrintableKeysAndBackspace()
        selectLeavesTabReturnAndEscToTheSheet()
        searchMovesTheHighlightWithArrowsAndControlNP()
        searchTabAndReturnPickWhenARowShows()
        searchTabAndReturnEndTheSearchWhenNoRowShows()
        searchEscRestoresTheValue()
        searchLeavesShiftTabAndOtherModifiedKeysToTheSheet()
        modelTabTakesTheRowThenMovesOn()
        projectTabTakesTheNameThenMovesOn()
        pathTabTakesTheRowAndDoesNotDrillDown()
        pathTabCompletesOrMovesOn()
        print("PickerFieldKeyTests: all tests passed")
    }

    private static func selectStartsASearchOnPrintableKeysAndBackspace() {
        expect(key("h", 4, mode: .select) == .startSearch(.seed("h")), "a printable key should start a search on that text")
        expect(key("O", 31, modifiers: [.shift], mode: .select) == .startSearch(.seed("O")), "a shifted key should start a search too")
        expect(key(nil, 51, mode: .select) == .startSearch(.editCurrent), "Backspace should edit the current text")
        expect(key("h", 4, modifiers: [.command], mode: .select) == nil, "⌘ keys should stay the sheet's")
        expect(key("h", 4, modifiers: [.control], mode: .select) == nil, "⌃ keys should stay the field's and the sheet's")
        expect(key("h", 4, modifiers: [.option], mode: .select) == nil, "⌥ keys should stay the field's")
    }

    private static func selectLeavesTabReturnAndEscToTheSheet() {
        expect(key("\t", 48, mode: .select) == nil, "Tab in SELECT should move on, so the field doesn't take it")
        expect(key("\r", 36, mode: .select) == nil, "Return in SELECT should submit, so the field doesn't take it")
        expect(key("\u{1b}", 53, mode: .select) == nil, "Esc in SELECT should close the sheet")
        expect(key("", 126, mode: .select) == nil && key("", 125, mode: .select) == nil, "↑/↓ in SELECT have no list to move")
    }

    private static func searchMovesTheHighlightWithArrowsAndControlNP() {
        expect(key("", 126, mode: .search, showsSuggestions: true) == .moveHighlight(-1), "↑ should move the highlight up")
        expect(key("", 125, mode: .search, showsSuggestions: false) == .moveHighlight(1), "↓ should move the highlight down, list or not")
        expect(key("p", 35, modifiers: [.control], mode: .search, showsSuggestions: true) == .moveHighlight(-1), "⌃p should move the highlight up")
        expect(key("n", 45, modifiers: [.control], mode: .search, showsSuggestions: true) == .moveHighlight(1), "⌃n should move the highlight down")
        expect(key("n", 45, mode: .search, showsSuggestions: true) == nil, "a plain n should type while searching")
        expect(key("p", 35, modifiers: [.control], mode: .select) == nil, "⌃p does nothing in SELECT")
        expect(key("e", 14, modifiers: [.control], mode: .search, showsSuggestions: true) == nil, "⌃e stays the field's own key")
    }

    private static func searchTabAndReturnPickWhenARowShows() {
        expect(key("\t", 48, mode: .search, showsSuggestions: true) == .pick, "Tab should take the highlighted row")
        expect(key("\r", 36, mode: .search, showsSuggestions: true) == .pick, "Return should take the highlighted row")
    }

    private static func searchTabAndReturnEndTheSearchWhenNoRowShows() {
        expect(key("\t", 48, mode: .search, showsSuggestions: false) == .endSearch, "Tab with no row should end the search")
        expect(key("\r", 36, mode: .search, showsSuggestions: false) == .endSearch, "Return with no row should end the search")
        expect(key("a", 0, mode: .search, showsSuggestions: true) == nil, "letters should type while searching")
        expect(key("\u{7f}", 51, mode: .search, showsSuggestions: true) == nil, "Backspace should edit the text while searching")
    }

    private static func searchEscRestoresTheValue() {
        expect(key("\u{1b}", 53, mode: .search, showsSuggestions: true) == .restore, "Esc should restore while a row shows")
        expect(key("\u{1b}", 53, mode: .search, showsSuggestions: false) == .restore, "Esc should restore with no row")
    }

    private static func searchLeavesShiftTabAndOtherModifiedKeysToTheSheet() {
        expect(key("\t", 48, modifiers: [.shift], mode: .search, showsSuggestions: true) == nil, "⇧Tab should move back, so the field doesn't take it")
        expect(key("", 126, modifiers: [.option], mode: .search, showsSuggestions: true) == nil, "⌥ keys should stay the text system's")
        expect(key("", 126, modifiers: [.command], mode: .search, showsSuggestions: true) == nil, "⌘↑ should stay the sheet's")
    }

    /// Tab takes the highlighted model, and the next Tab moves on: the second Tab is no picker key.
    private static func modelTabTakesTheRowThenMovesOn() {
        var model = NewSessionFormModel(initialPath: "/tmp/project", initialFocus: .model)
        model.setModelOptions([SessionModelOption(id: "claude-opus-5-5", label: "claude-opus-5-5")])
        model.startModelSearch(.seed("o"))
        model.typeModel("opus")
        expect(model.showsModelSuggestions, "precondition: a match shows while searching")

        let firstTab = PickerFieldKey.command(Keymap.KeyPress(keyCode: 48, character: "\t", modifiers: []), mode: model.modelMode, showsSuggestions: model.showsModelSuggestions)
        expect(firstTab == .pick, "the first Tab should pick")
        model.applyModelCommand(firstTab!)
        expect(model.selectedModel == "claude-opus-5-5" && model.modelMode == .select, "picking should take the row and return to SELECT")

        let secondTab = PickerFieldKey.command(Keymap.KeyPress(keyCode: 48, character: "\t", modifiers: []), mode: model.modelMode, showsSuggestions: model.showsModelSuggestions)
        expect(secondTab == nil, "the second Tab should be the sheet's, moving on")
    }

    /// Tab takes the highlighted project name, and the next Tab moves on.
    private static func projectTabTakesTheNameThenMovesOn() {
        let projects = [NewQuestProjectOption(projectID: "/tmp/a/.git", projectPath: "/tmp/a", projectName: "a")]
        var form = NewQuestFormModel(projects: projects, home: "/Users/me")
        form.startProjectSearch(.seed("a"))
        expect(form.showsProjectSuggestions && form.highlightedProject?.displayName == "a", "precondition: the name shows and is highlighted")

        let firstTab = PickerFieldKey.command(Keymap.KeyPress(keyCode: 48, character: "\t", modifiers: []), mode: form.projectMode, showsSuggestions: form.showsProjectSuggestions)
        expect(firstTab == .pick, "the first Tab should pick the name")
        form.applyProjectCommand(firstTab!)
        expect(form.projectText == "a" && form.projectMode == .select, "picking should show the name and return to SELECT")
        expect(PickerFieldKey.command(Keymap.KeyPress(keyCode: 48, character: "\t", modifiers: []), mode: form.projectMode, showsSuggestions: form.showsProjectSuggestions) == nil, "the second Tab should move on")
    }

    /// A path's Tab takes the highlighted directory and leaves the path's own text to the field: it never
    /// lists the directory's contents, so a Tab can't drill down. Typing a `/` does that.
    private static func pathTabTakesTheRowAndDoesNotDrillDown() {
        var rows = SuggestionList()
        rows.show(["/Users/me/code", "/Users/me/docs"])
        rows.moveHighlight(1)
        expect(rows.tabOutcome(path: "/Users/me/", completion: { _ in "/Users/me/" }) == .choose("/Users/me/docs"), "Tab should take the highlighted directory")

        rows.dismiss()
        expect(rows.tabOutcome(path: "/Users/me/docs", completion: { _ in "/Users/me/docs" }) == .moveOn, "Tab with the rows closed and nothing to complete should move on, not drill down")
    }

    private static func pathTabCompletesOrMovesOn() {
        let rows = SuggestionList()
        expect(rows.tabOutcome(path: "/Users/me/co", completion: { _ in "/Users/me/code/" }) == .choose("/Users/me/code/"), "with no rows, Tab should complete from disk when that changes the path")
        expect(rows.tabOutcome(path: "/Users/me/co", completion: { $0 }) == .moveOn, "with no rows and nothing to complete, Tab should move on")
    }

    /// The key the picker resolves, from a SELECT or SEARCH state.
    private static func key(
        _ characters: String?,
        _ keyCode: UInt16,
        modifiers: Set<Keymap.Modifier> = [],
        mode: PickerFieldMode,
        showsSuggestions: Bool = false
    ) -> PickerFieldCommand? {
        PickerFieldKey.command(Keymap.KeyPress(keyCode: keyCode, character: characters, modifiers: modifiers), mode: mode, showsSuggestions: showsSuggestions)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fail(message)
        }
    }

    private static func fail(_ message: String) -> Never {
        fputs("PickerFieldKeyTests failed: \(message)\n", stderr)
        Foundation.exit(1)
    }
}
