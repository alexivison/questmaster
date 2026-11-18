import Foundation
import QuestmasterCore

struct QuestAttachmentKeyboardTests {
    static func run() {
        formCursorRemovesStoredAndPendingFiles()
        logCursorOpensAndRemovesOnlyTheFocusedFile()
        logCursorSurvivesRemovalAndReturnsToTheList()
        removalRequestPreservesOtherQuestFields()
        print("QuestAttachmentKeyboardTests: all tests passed")
    }

    private static func file(_ id: String) -> QuestAttachment {
        QuestAttachment(id: id, name: "\(id).png", path: "/tmp/example-app/\(id).png", size: 4)
    }

    private static func formCursorRemovesStoredAndPendingFiles() {
        let first = file("att-first"), second = file("att-second")
        var form = NewQuestFormModel(content: "Example", isEditing: true, attachments: [first, second])
        form.focusAttachment(.chooseFiles)
        expect(form.focusedField == .attachments && form.modalFocus == .select, "attachments should be a field with select keys")
        form.cycleAttachment(1)
        expect(form.attachmentTarget == .stored(first.id) && form.focusedAttachmentPath == first.path, "l should reach the first stored file")
        form.removeAttachment(form.attachmentTarget)
        expect(form.attachmentTarget == .stored(second.id), "removing a chip should keep the cursor on its next neighbour")
        form.addAttachmentPaths(["/tmp/example-app/draft.png"])
        form.cycleAttachment(1)
        expect(form.attachmentTarget == .pending("/tmp/example-app/draft.png"), "the cursor should reach pending files too")
        form.removeAttachment(form.attachmentTarget)
        expect(form.attachPaths.isEmpty && form.attachmentTarget == .stored(second.id), "removing the last pending file should recover to the previous chip")
        form.submitting = true
        form.removeAttachment(form.attachmentTarget)
        expect(form.attachments == [second], "a submit in flight must hold attachment changes")
        form.submitting = false
        form.removeAttachment(form.attachmentTarget)
        expect(form.attachmentTarget == .chooseFiles && form.focusedAttachmentPath == nil, "removing all files should return to Choose a File")
        expect(form.submitPayload()?.detachIDs == [first.id, second.id], "only saving the form should schedule stored file removal")
        form.focusedField = .content
        form.moveFocus(-1)
        expect(form.focusedField == .attachments, "Ctrl+K from the body should return to attachments")
        form.moveFocus(1)
        expect(form.focusedField == .content, "Ctrl+J should return to the body")
    }

    private static func logCursorOpensAndRemovesOnlyTheFocusedFile() {
        let attachment = file("att-first")
        let first = QuestItem(id: "qst-first", content: "First", attachments: [attachment])
        let marked = QuestItem(id: "qst-marked", content: "Marked")
        let store = QuestLogStore()
        store.sync(quests: [first, marked], repos: [])
        store.select(marked.id)
        _ = store.handle(.toggleMark)
        store.select(first.id)
        _ = store.command(for: Keymap.KeyPress(keyCode: 37, character: "l"))
        expect(store.focusedAttachmentID == attachment.id, "l should enter the selected quest's thumbnails")
        expect(store.command(for: Keymap.KeyPress(keyCode: 36, character: "\r")) == .open, "Return should open a focused thumbnail")
        expect(store.handle(.open) == .openAttachment(attachment), "opening should use the focused file")
        _ = store.command(for: Keymap.KeyPress(keyCode: 5, character: "g"))
        _ = store.command(for: Keymap.KeyPress(keyCode: 36, character: "\r"))
        expect(store.command(for: Keymap.KeyPress(keyCode: 5, character: "g")) == .jumpToTopPrefix, "opening a file should cancel an armed g chord")
        expect(store.handle(.delete) == .removeAttachment(first, attachment), "d on a thumbnail must target that file, even when another quest is marked")
        expect(store.handle(.close) == nil && !store.attachmentsFocused, "Esc should return to the quest list first")
        expect(store.handle(.delete) == .delete([marked]), "quest deletion should keep its existing marked-quest semantics while the list has focus")
        expect(store.handle(.close) == .close, "Esc in the quest list should close the modal")
    }

    private static func logCursorSurvivesRemovalAndReturnsToTheList() {
        let first = file("att-first"), second = file("att-second")
        var quest = QuestItem(id: "qst-example", content: "Example", attachments: [first, second])
        let store = QuestLogStore()
        store.sync(quests: [quest], repos: [])
        store.moveAttachment(1)
        store.moveAttachment(1)
        expect(store.focusedAttachmentID == second.id, "l should step through files")
        quest.attachments = [first]
        store.sync(quests: [quest], repos: [])
        expect(store.focusedAttachmentID == first.id && store.attachmentsFocused, "a refresh should recover the cursor to the adjacent file")
        quest.attachments = []
        store.sync(quests: [quest], repos: [])
        expect(store.focusedAttachmentID == nil && store.attachmentsFocused, "removing the final file should keep focus in the file area")
        expect(store.handle(.delete) == nil, "a repeated d after the final removal must never become quest deletion")
        store.moveAttachment(-1)
        expect(!store.attachmentsFocused, "h should leave an empty attachment area")
        quest.attachments = [first]
        store.sync(quests: [quest], repos: [])
        store.moveAttachment(1)
        _ = store.handle(.move(1))
        expect(!store.attachmentsFocused && store.focusedAttachmentID == nil, "j/k should return to quest navigation")
    }

    private static func removalRequestPreservesOtherQuestFields() {
        do {
            let request = try ServeMutationRequests.questDetachAttachment(questID: "qst-example", attachmentID: "att-example")
            expect(request.method == "quest.edit" && request.data == ["quest_id": "qst-example"], "attachment removal should leave content, project and tags out of the mutation")
            expect(request.lists == ["detach_ids": ["att-example"]], "the mutation should identify only the file to remove")
            let confirmation = DestructiveConfirmation.removeQuestAttachment(file("att-example"))
            expect(confirmation.action == .removeQuestAttachment && confirmation.subjectID == "att-example", "confirmation should identify the attachment")
            expect(confirmation.message.contains("stored copy") && confirmation.message.contains("original file"), "confirmation should explain which file will be removed")
        } catch { expect(false, "attachment removal request threw \(error)") }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("QuestAttachmentKeyboardTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
