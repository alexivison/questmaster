import Foundation
import QuestmasterCore

struct QuestTagsTests {
    static func run() {
        tagTypesAreFixedAndNamedInOrder()
        sizeCyclesNoneSmallMediumLargeInBothDirections()
        fieldOpensOnTheQuestsKnownTypes()
        chipsKeepTheFixedOrder()
        emptyQueryListsEveryOpenType()
        queryFiltersTheRowsByName()
        rankingPutsPrefixMatchesBeforeContainingOnes()
        acceptAddsAChipAndClearsTheQuery()
        returnTakesTheHighlightedRowOnlyWhileAQueryMatches()
        tabAndTheVerticalChordsPassThrough()
        upAndDownMoveTheHighlightWithWrap()
        spaceTypesNothing()
        eTypesAndCtrlEPassesThrough()
        backspaceRemovesTheLastChipOnlyInAnEmptyQuery()
        chipRemovalPutsTheTypeBackInTheRows()
        escClearsTheQueryThenPassesThrough()
        newQuestHasNoTagsOrSizeField()
        editFormListsTagsThenSizeBetweenProjectAndContent()
        sizeSelectTakesTheSelectKeys()
        editFormSendsNoTagsOrSizeWhenUntouched()
        editFormSendsTheTypesTheUserChanged()
        editFormClearsTypesWithAnEmptyList()
        editFormSendsTheSizeOnlyWhenTheUserChangedIt()
        editFormClearsTheSizeWithAnEmptyValue()
        typedTextIsNotATag()
        requestEncodesTypesAndSizeAsBefore()
    }

    private static func tagTypesAreFixedAndNamedInOrder() {
        expect(
            QuestTagType.allCases.map(\.displayName) == ["Bug", "Improvement", "Feature", "Research", "Decision", "Cleanup"],
            "the type tags should be the six fixed types, named and listed in order"
        )
        expect(QuestSize.allCases.map(\.rawValue) == ["S", "M", "L"], "the sizes should be S, M and L")
    }

    private static func sizeCyclesNoneSmallMediumLargeInBothDirections() {
        var forward: [String] = []
        var size: QuestSize?
        for _ in 0..<4 {
            size = QuestSize.cycled(from: size, by: 1)
            forward.append(size?.rawValue ?? "none")
        }
        expect(forward == ["S", "M", "L", "none"], "stepping forward should go none, S, M, L and back to none, got \(forward)")

        var backward: [String] = []
        for _ in 0..<4 {
            size = QuestSize.cycled(from: size, by: -1)
            backward.append(size?.rawValue ?? "none")
        }
        expect(backward == ["L", "M", "S", "none"], "stepping back should reverse the order, got \(backward)")
    }

    private static func fieldOpensOnTheQuestsKnownTypes() {
        let field = QuestTagsField(types: ["feature", "bug", "unknown"])
        expect(field.selected == [.bug, .feature], "unknown types should not be shown as chosen")
        expect(field.tokens.map(\.title) == ["Bug", "Feature"], "the chips should name the chosen types, got \(field.tokens.map(\.title))")
        expect(field.query == "", "the field should open with an empty query")
    }

    private static func chipsKeepTheFixedOrder() {
        var field = QuestTagsField()
        field.choose(.research)
        field.choose(.bug)
        expect(field.selectedTypes == [.bug, .research], "a chosen type should join the fixed order, got \(field.selectedTypes)")
        expect(field.tokens.map(\.kind) == [.type, .type] && field.tokens.map(\.value) == ["bug", "research"], "each chip should be a type token")
    }

    private static func emptyQueryListsEveryOpenType() {
        var field = QuestTagsField()
        expect(field.rows == QuestTagType.allCases, "with no query every type should be listed, got \(field.rows)")
        field.choose(.bug)
        expect(field.rows == Array(QuestTagType.allCases.dropFirst()), "a chosen type should drop out of the rows, got \(field.rows)")
    }

    private static func queryFiltersTheRowsByName() {
        var field = QuestTagsField()
        field.typeQuery("clean")
        expect(field.rows == [.cleanup], "the query should match only Cleanup, got \(field.rows)")
        field.typeQuery("BUG")
        expect(field.rows == [.bug], "matching should ignore case, got \(field.rows)")
        field.typeQuery("zz")
        expect(field.rows.isEmpty && field.highlightedRow == nil, "a query no type matches should leave no rows")
    }

    private static func rankingPutsPrefixMatchesBeforeContainingOnes() {
        var field = QuestTagsField()
        field.typeQuery("i")
        expect(field.rows == [.improvement, .decision], "a prefix match should rank before one that contains the query, got \(field.rows)")
    }

    private static func acceptAddsAChipAndClearsTheQuery() {
        var field = QuestTagsField()
        field.typeQuery("fea")
        expect(field.highlightedRow == .feature, "the best match should be highlighted")
        expect(field.handle(press(nil, keyCode: 36)), "Return should take the highlighted row")
        expect(field.selectedTypes == [.feature], "the row should become a chip")
        expect(field.query == "" && field.rows.count == QuestTagType.allCases.count - 1, "accepting should clear the query and drop the chosen type from the rows")
    }

    private static func returnTakesTheHighlightedRowOnlyWhileAQueryMatches() {
        var field = QuestTagsField()
        expect(!field.handle(press(nil, keyCode: 36)) && field.selected.isEmpty, "Return with no query should pass to the form, which submits")
        field.typeQuery("zz")
        expect(!field.handle(press(nil, keyCode: 36)) && field.selected.isEmpty, "Return with no matching row should pass to the form")
        field.typeQuery("bu")
        expect(field.handle(press(nil, keyCode: 36)) && field.selectedTypes == [.bug], "Return with a matching query should add the highlighted type")
        expect(!field.handle(press(nil, [.command], keyCode: 36)), "⌘Return should submit the form")
    }

    private static func tabAndTheVerticalChordsPassThrough() {
        var field = QuestTagsField()
        field.typeQuery("b")
        expect(!field.handle(press(nil, keyCode: 48)), "Tab should move between fields, not be taken by the tags field")
        expect(!field.handle(press(nil, [.shift], keyCode: 48)), "⇧Tab should move between fields")
        expect(!field.handle(press("j", [.control], keyCode: 38)), "⌃j should move between fields")
        expect(!field.handle(press("k", [.control], keyCode: 40)), "⌃k should move between fields")
        expect(field.selected.isEmpty && field.query == "b", "the passed-through keys should change nothing")
    }

    private static func upAndDownMoveTheHighlightWithWrap() {
        var field = QuestTagsField()
        expect(field.handle(press(nil, keyCode: 125)) && field.highlightedIndex == 1, "↓ should move the dropdown's highlight to the next row")
        expect(field.handle(press(nil, keyCode: 126)) && field.handle(press(nil, keyCode: 126)), "↑ should move the highlight back")
        expect(field.highlightedIndex == QuestTagType.allCases.count - 1, "↑ from the first row should wrap to the last")
        expect(field.handle(press("n", [.control], keyCode: 45)) && field.highlightedIndex == 0, "⌃n should move down and wrap")
        field.typeQuery("zz")
        expect(!field.handle(press(nil, keyCode: 125)), "with no rows ↓ should pass to the text")
    }

    private static func spaceTypesNothing() {
        var field = QuestTagsField()
        field.typeQuery("bu")
        expect(field.handle(press(" ", keyCode: 49)), "Space should be taken by the tags field")
        expect(field.query == "bu" && field.selected.isEmpty, "Space should type nothing and choose nothing")
    }

    private static func eTypesAndCtrlEPassesThrough() {
        var field = QuestTagsField()
        expect(!field.handle(press("e", keyCode: 14)), "e should type into the field")
        expect(!field.handle(press(nil, [.control], keyCode: 14)), "⌃e should be the text field's own key, not a size cycle")
        expect(field.selected.isEmpty, "neither key should choose a type")
    }

    private static func backspaceRemovesTheLastChipOnlyInAnEmptyQuery() {
        var field = QuestTagsField(types: ["bug", "research"])
        field.typeQuery("x")
        expect(!field.handle(press("\u{7F}", keyCode: 51)) && field.selectedTypes == [.bug, .research], "Backspace in a query should edit the text, not a chip")
        field.typeQuery("")
        expect(field.handle(press("\u{7F}", keyCode: 51)) && field.selectedTypes == [.bug], "Backspace in an empty query should remove the last chip")
        _ = field.handle(press("\u{7F}", keyCode: 51))
        expect(field.selected.isEmpty, "Backspace should keep removing chips from the end")
        expect(!field.handle(press("\u{7F}", keyCode: 51)), "Backspace with no chips and no query should do nothing")
    }

    private static func chipRemovalPutsTheTypeBackInTheRows() {
        var field = QuestTagsField(types: ["bug", "research"])
        field.remove(.bug)
        expect(field.selectedTypes == [.research], "removing a chip should remove that type only")
        expect(field.rows.contains(.bug), "a removed type should be listed again")
    }

    private static func escClearsTheQueryThenPassesThrough() {
        var field = QuestTagsField()
        field.typeQuery("b")
        expect(field.handle(press("\u{1B}", keyCode: 53)) && field.query == "", "Esc should clear a typed query")
        expect(!field.handle(press("\u{1B}", keyCode: 53)), "Esc with no query should pass to the sheet, which closes")
    }

    private static func newQuestHasNoTagsOrSizeField() {
        var model = NewQuestFormModel(content: "Loose note", initialProject: projects[0], projects: projects, home: home, types: ["bug"], size: "S")
        expect(model.fields == [.project, .content], "New Quest should have no tags or size field, got \(model.fields)")
        model.focusedField = .project
        model.moveFocus(1)
        expect(model.focusedField == .content, "Tab from the project should reach the content")
        let payload = model.submitPayload()
        expect(payload != nil && payload?.types == nil && payload?.size == nil, "New Quest should send no tags, even when handed some")
    }

    private static func editFormListsTagsThenSizeBetweenProjectAndContent() {
        var model = NewQuestFormModel(content: "Quest", initialProject: projects[0], isEditing: true, projects: projects, home: home)
        expect(model.fields == [.project, .tags, .size, .content], "Edit Quest should list tags then size between project and content, got \(model.fields)")
        model.focusedField = .project
        model.moveFocus(1)
        expect(model.focusedField == .tags, "Tab from the project should reach the tags field")
        model.moveFocus(1)
        expect(model.focusedField == .size, "Tab from the tags field should reach the size field")
        model.moveFocus(1)
        expect(model.focusedField == .content, "Tab from the size field should reach the content")
    }

    /// The size select has no text, so its focus is `.select`: ←/→ and h/l cycle it, and ↑/↓ do nothing.
    private static func sizeSelectTakesTheSelectKeys() {
        var model = NewQuestFormModel(content: "Quest", initialProject: projects[0], isEditing: true, projects: projects, home: home)
        model.focusedField = .size
        expect(model.modalFocus == .select, "the size field should be a select to the modal keys")
        let context = ModalKeyContext(focus: model.modalFocus, fieldCount: model.fields.count, hasTextFields: true, submitting: false, submits: true)
        expect(ModalKeys.command(for: press("h", keyCode: 4), in: context) == .cycle(-1), "h should step the size back")
        expect(ModalKeys.command(for: press("l", keyCode: 37), in: context) == .cycle(1), "l should step the size forward")
        expect(ModalKeys.command(for: press(nil, keyCode: 123), in: context) == .cycle(-1), "← should step the size back")
        expect(ModalKeys.command(for: press(nil, keyCode: 124), in: context) == .cycle(1), "→ should step the size forward")
        expect(ModalKeys.command(for: press(nil, keyCode: 126), in: context) == .consume, "↑ should not move a select")
        model.cycleSize(1)
        expect(model.size == .small, "one step from none should be S")
        model.cycleSize(-1)
        model.cycleSize(-1)
        expect(model.size == .large, "a step back from none should wrap to L")
        model.focusedField = .tags
        expect(model.modalFocus == .line, "the tags field should take typed letters, not the select keys")
    }

    private static func editFormSendsNoTagsOrSizeWhenUntouched() {
        var model = NewQuestFormModel(content: "Quest", initialProject: projects[0], isEditing: true, projects: projects, home: home, types: ["bug", "feature"], size: "M")
        let payload = model.submitPayload()
        expect(payload?.types == nil && payload?.size == nil, "untouched tags and size should be absent, so the quest keeps them")
        let request = try? ServeMutationRequests.questEdit(questID: "qst-1", payload: payload!)
        expect(request?.lists["types"] == nil && request?.data["size"] == nil, "the edit should send neither tag field")
    }

    private static func editFormSendsTheTypesTheUserChanged() {
        var model = NewQuestFormModel(content: "Quest", initialProject: projects[0], isEditing: true, projects: projects, home: home, types: ["bug"])
        model.focusedField = .tags
        model.tags.typeQuery("research")
        expect(model.tags.handle(press(nil, keyCode: 36)), "Return should add the typed type")
        let payload = model.submitPayload()
        expect(payload?.types == ["bug", "research"], "the changed types should be sent in order, got \(String(describing: payload?.types))")
        expect(payload?.size == nil, "an untouched size should stay absent")
        let request = try? ServeMutationRequests.questEdit(questID: "qst-1", payload: payload!)
        expect(request?.lists["types"] == ["bug", "research"], "the types should go as a JSON list")
    }

    private static func editFormClearsTypesWithAnEmptyList() {
        var model = NewQuestFormModel(content: "Quest", initialProject: projects[0], isEditing: true, projects: projects, home: home, types: ["bug"])
        model.tags.remove(.bug)
        let payload = model.submitPayload()
        expect(payload?.types == [], "removing every chip should send an empty list, which clears the types")
        let request = try? ServeMutationRequests.questEdit(questID: "qst-1", payload: payload!)
        expect(request?.lists["types"] == [], "an empty list should be sent, not omitted")
    }

    private static func editFormSendsTheSizeOnlyWhenTheUserChangedIt() {
        var model = NewQuestFormModel(content: "Quest", initialProject: projects[0], isEditing: true, projects: projects, home: home, types: ["bug"])
        model.focusedField = .size
        model.cycleSize(1)
        let payload = model.submitPayload()
        expect(payload?.types == nil && payload?.size == "S", "changing only the size should leave the types absent and send S")
    }

    private static func editFormClearsTheSizeWithAnEmptyValue() {
        var model = NewQuestFormModel(content: "Quest", initialProject: projects[0], isEditing: true, projects: projects, home: home, size: "M")
        model.cycleSize(1)
        model.cycleSize(1)
        expect(model.size == nil, "stepping past L should return to no size")
        let payload = model.submitPayload()
        expect(payload?.size == "", "stepping back to none should send an empty size, which clears it")
        let request = try? ServeMutationRequests.questEdit(questID: "qst-1", payload: payload!)
        expect(request?.data["size"] == "", "an empty size should be sent, not omitted")
    }

    /// Text in the tags field is a query, not a type: submitting it with nothing chosen sends no types.
    private static func typedTextIsNotATag() {
        var model = NewQuestFormModel(content: "Quest", initialProject: projects[0], isEditing: true, projects: projects, home: home)
        model.focusedField = .tags
        model.tags.typeQuery("bu")
        let payload = model.submitPayload()
        expect(payload?.types == nil, "a query that was never chosen should not be sent as a type")
    }

    private static func requestEncodesTypesAndSizeAsBefore() {
        var model = NewQuestFormModel(content: "Quest", initialProject: projects[0], isEditing: true, projects: projects, home: home, types: ["bug"], size: "L")
        model.tags.choose(.decision)
        model.cycleSize(1)
        let payload = model.submitPayload()
        let request = try? ServeMutationRequests.questEdit(questID: "qst-1", payload: payload!)
        expect(request?.lists["types"] == ["bug", "decision"], "the types should go as ordered rows, got \(String(describing: request?.lists["types"]))")
        expect(request?.data["size"] == "", "L stepped forward is none, which is sent as an empty size")
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
