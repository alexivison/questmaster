import Foundation
import QuestmasterCore

struct QuestTagsTests {
    static func run() {
        tagTypesAreFixedAndNamedInOrder()
        sizeCyclesNoneSmallMediumLargeThenNone()
        fieldOpensOnTheQuestsKnownTags()
        togglingKeepsTheFixedOrder()
        spaceTogglesTheHighlightedRowAndKeepsTheDropdown()
        arrowsMoveTheHighlightWithWrap()
        printableKeySeedsASearchThatFiltersRows()
        searchTextReplacesTheRowsUntilItEnds()
        togglesInASearchReachTheFilteredRows()
        segmentKeyCyclesSizeInBothStates()
        keysThatBelongToTheFormPassThrough()
        escEndsOnlyASearch()
        noMatchingRowsShowNoDropdown()
        newQuestHasNoTagsField()
        editFormPutsTagsBetweenProjectAndContent()
        editFormSendsNoTagsWhenUntouched()
        editFormSendsTheTypesAndSizeTheUserChanged()
        editFormClearsTypesAndSizeWithEmptyValues()
        editFormSendsOnlyTheSizeWhenOnlyTheSizeChanged()
        leavingTheTagsFieldEndsItsSearch()
    }

    private static func tagTypesAreFixedAndNamedInOrder() {
        expect(
            QuestTagType.allCases.map(\.displayName) == ["Bug", "Improvement", "Feature", "Research", "Decision", "Cleanup"],
            "the type tags should be the six fixed types, named and listed in order"
        )
        expect(QuestSize.allCases.map(\.rawValue) == ["S", "M", "L"], "the sizes should be S, M and L")
    }

    private static func sizeCyclesNoneSmallMediumLargeThenNone() {
        var size: QuestSize?
        var seen: [String] = []
        for _ in 0..<4 {
            size = QuestSize.next(after: size)
            seen.append(size?.rawValue ?? "none")
        }
        expect(seen == ["S", "M", "L", "none"], "the size should cycle none, S, M, L and back to none, got \(seen)")
    }

    private static func fieldOpensOnTheQuestsKnownTags() {
        let field = QuestTagsField(types: ["feature", "bug", "unknown"], size: "M")
        expect(field.selected == [.bug, .feature], "unknown types should not be shown as chosen")
        expect(field.text == "Bug, Feature", "the field should show the chosen names in order, got \(field.text)")
        expect(field.sizeLabel == "M", "the segment should show the quest's size")

        let untagged = QuestTagsField(types: [], size: "")
        expect(untagged.text == "" && untagged.sizeLabel == QuestTagsField.noSizeLabel, "an untagged quest should show no types and no size")
    }

    private static func togglingKeepsTheFixedOrder() {
        var field = QuestTagsField()
        field.toggleRow(at: 3)
        field.toggleRow(at: 0)
        expect(field.selectedTypes == [.bug, .research], "a toggled type should join the fixed order, got \(field.selectedTypes)")
        expect(field.checkedRows == [0, 3], "the checked rows should be the chosen types' positions")
        field.toggleRow(at: 3)
        expect(field.selectedTypes == [.bug], "a second toggle should untick the row")
    }

    private static func spaceTogglesTheHighlightedRowAndKeepsTheDropdown() {
        var field = QuestTagsField()
        expect(field.handle(press(" ", keyCode: 49)), "Space should be taken by the tags field")
        expect(field.selectedTypes == [.bug], "Space should tick the highlighted row")
        expect(field.rows.count == QuestTagType.allCases.count, "toggling should leave every row in the dropdown")
        expect(field.handle(press(" ", keyCode: 49)) && field.selectedTypes.isEmpty, "a second Space should untick it")
    }

    private static func arrowsMoveTheHighlightWithWrap() {
        var field = QuestTagsField()
        expect(field.handle(press(nil, keyCode: 125)), "↓ should move the dropdown's highlight")
        expect(field.highlightedIndex == 1, "↓ should move to the next row")
        expect(field.handle(press(nil, keyCode: 126)) && field.handle(press(nil, keyCode: 126)), "↑ should move the highlight back")
        expect(field.highlightedIndex == 5, "↑ from the first row should wrap to the last")
        expect(field.handle(press("n", [.control], keyCode: 45)) && field.highlightedIndex == 0, "⌃n should move down and wrap")
    }

    private static func printableKeySeedsASearchThatFiltersRows() {
        var field = QuestTagsField()
        expect(field.handle(press("f", keyCode: 3)), "a printable key in SELECT should start a search")
        expect(field.mode == .search && field.query == "f", "the key should seed the query")
        expect(field.rows == [.feature], "the query should filter the rows by name, got \(field.rows)")
    }

    private static func searchTextReplacesTheRowsUntilItEnds() {
        var field = QuestTagsField(types: ["research"])
        field.startSearch("r")
        field.typeQuery("res")
        expect(field.rows == [.research], "typed text should filter the rows")
        expect(field.text == "res", "while searching the field shows what was typed")
        field.endSearch()
        expect(field.rows == QuestTagType.allCases && field.text == "Research", "ending the search should restore the rows and the chosen types")
    }

    private static func togglesInASearchReachTheFilteredRows() {
        var field = QuestTagsField()
        field.startSearch("clean")
        expect(field.rows == [.cleanup], "the query should match only Cleanup, got \(field.rows)")
        field.toggleRow(at: 0)
        expect(field.selectedTypes == [.cleanup], "a click in a search should toggle the row it shows")
        expect(field.checkedRows == [0], "the filtered row should be ticked in the search")
    }

    private static func segmentKeyCyclesSizeInBothStates() {
        var field = QuestTagsField()
        expect(field.handle(press("e", keyCode: 14)) && field.size == .small, "e should cycle the size in SELECT")
        field.startSearch("x")
        expect(!field.handle(press("e", keyCode: 14)) && field.query == "x", "e should type while searching, not cycle the size")
        expect(field.handle(press(nil, [.control], keyCode: 14)) && field.size == .medium, "⌃e should cycle the size while searching")
        field.endSearch()
        expect(field.handle(press(nil, [.control], keyCode: 14)) && field.size == .large, "⌃e should cycle the size in SELECT")
        expect(field.handle(press("e", keyCode: 14)) && field.size == nil, "the cycle should return to none")
    }

    private static func keysThatBelongToTheFormPassThrough() {
        var field = QuestTagsField()
        expect(!field.handle(press(nil, keyCode: 48)), "Tab should move between fields, not be taken by the tags field")
        expect(!field.handle(press("\r", keyCode: 36)), "Return should submit, not be taken by the tags field")
        expect(!field.handle(press("\u{7F}", keyCode: 51)), "Backspace in SELECT should do nothing here")
        expect(!field.handle(press("\u{1B}", keyCode: 53)), "Esc in SELECT should close the sheet")
        expect(field.mode == .select && field.selected.isEmpty && field.size == nil, "the passed-through keys should change nothing")
    }

    private static func escEndsOnlyASearch() {
        var field = QuestTagsField()
        field.startSearch("b")
        expect(field.handle(press("\u{1B}", keyCode: 53)), "Esc should end a search")
        expect(field.mode == .select && field.query == "", "Esc should clear the query and return to SELECT")
    }

    private static func noMatchingRowsShowNoDropdown() {
        var field = QuestTagsField()
        field.startSearch("zz")
        expect(field.rows.isEmpty && field.checkedRows.isEmpty, "a query no type matches should leave no rows")
        field.toggleRow(at: 0)
        expect(field.selected.isEmpty, "with no rows a click should toggle nothing")
    }

    private static func newQuestHasNoTagsField() {
        var model = NewQuestFormModel(content: "Loose note", initialProject: projects[0], projects: projects, home: home, types: ["bug"], size: "S")
        expect(model.fields == [.project, .content], "New Quest should have no tags field, got \(model.fields)")
        expect(!model.showsTagRows, "New Quest should show no tag dropdown")
        model.focusedField = .project
        model.moveFocus(1)
        expect(model.focusedField == .content, "Tab from the project should reach the content, not a tags field")
        let payload = model.submitPayload()
        expect(payload != nil && payload?.types == nil && payload?.size == nil, "New Quest should send no tags, even when handed some")
    }

    private static func editFormPutsTagsBetweenProjectAndContent() {
        var model = NewQuestFormModel(content: "Quest", initialProject: projects[0], isEditing: true, projects: projects, home: home)
        expect(model.fields == [.project, .tags, .content], "Edit Quest should list the tags field between project and content")
        model.focusedField = .project
        model.moveFocus(1)
        expect(model.focusedField == .tags, "Tab from the project should reach the tags field")
        expect(model.showsTagRows, "a focused tags field with types should show its dropdown")
        model.moveFocus(1)
        expect(model.focusedField == .content, "Tab from the tags field should reach the content")
        expect(!model.showsTagRows, "the dropdown should close when the tags field loses focus")
    }

    private static func editFormSendsNoTagsWhenUntouched() {
        var model = NewQuestFormModel(content: "Quest", initialProject: projects[0], isEditing: true, projects: projects, home: home, types: ["bug", "feature"], size: "M")
        let payload = model.submitPayload()
        expect(payload?.types == nil && payload?.size == nil, "untouched tags should be absent, so the quest keeps them")
        let request = try? ServeMutationRequests.questEdit(questID: "qst-1", payload: payload!)
        expect(request?.lists["types"] == nil && request?.data["size"] == nil, "the edit should send neither tag field")
    }

    private static func editFormSendsTheTypesAndSizeTheUserChanged() {
        var model = NewQuestFormModel(content: "Quest", initialProject: projects[0], isEditing: true, projects: projects, home: home, types: ["bug"])
        model.focusedField = .tags
        model.tags.toggleRow(at: 3)
        model.tags.cycleSize()
        let payload = model.submitPayload()
        expect(payload?.types == ["bug", "research"], "the changed types should be sent in order, got \(String(describing: payload?.types))")
        expect(payload?.size == "S", "the changed size should be sent")
        let request = try? ServeMutationRequests.questEdit(questID: "qst-1", payload: payload!)
        expect(request?.lists["types"] == ["bug", "research"], "the types should go as a JSON list")
        expect(request?.data["size"] == "S", "the size should go as a string")
    }

    private static func editFormClearsTypesAndSizeWithEmptyValues() {
        var model = NewQuestFormModel(content: "Quest", initialProject: projects[0], isEditing: true, projects: projects, home: home, types: ["bug"], size: "M")
        model.focusedField = .tags
        model.tags.toggleRow(at: 0)
        model.tags.cycleSize()
        model.tags.cycleSize()
        let payload = model.submitPayload()
        expect(payload?.types == [], "unticking every type should send an empty list, which clears them")
        expect(payload?.size == "", "cycling the size back to none should send an empty size, which clears it")
        let request = try? ServeMutationRequests.questEdit(questID: "qst-1", payload: payload!)
        expect(request?.lists["types"] == [], "an empty list should be sent, not omitted")
        expect(request?.data["size"] == "", "an empty size should be sent, not omitted")
    }

    private static func editFormSendsOnlyTheSizeWhenOnlyTheSizeChanged() {
        var model = NewQuestFormModel(content: "Quest", initialProject: projects[0], isEditing: true, projects: projects, home: home, types: ["bug"])
        model.focusedField = .tags
        model.tags.cycleSize()
        let payload = model.submitPayload()
        expect(payload?.types == nil && payload?.size == "S", "changing only the size should leave the types absent")
    }

    private static func leavingTheTagsFieldEndsItsSearch() {
        var model = NewQuestFormModel(content: "Quest", initialProject: projects[0], isEditing: true, projects: projects, home: home)
        model.focusedField = .tags
        _ = model.tags.handle(press("f", keyCode: 3))
        expect(model.tags.mode == .search, "precondition: the tags field is searching")
        model.focusedField = .content
        expect(model.tags.mode == .select && model.tags.query == "", "leaving the tags field should end its search and clear the query")
    }

    private static let home = "/Users/me"
    private static let projects = [
        NewQuestProjectOption(projectID: "q", projectPath: "/Users/me/Code/questmaster", projectName: "questmaster"),
        NewQuestProjectOption(projectID: "s", projectPath: "/Users/me/Code/scry", projectName: "scry"),
    ]

    private static func press(_ characters: String?, _ modifiers: Set<Keymap.Modifier> = [], keyCode: UInt16) -> Keymap.KeyPress {
        Keymap.KeyPress(keyCode: keyCode, character: characters, modifiers: modifiers)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fail(message)
        }
    }

    private static func fail(_ message: String) -> Never {
        fputs("QuestTagsTests failed: \(message)\n", stderr)
        Foundation.exit(1)
    }
}
