import Foundation
import QuestmasterCore

struct QuestCommentComposerTests {
    static func run() {
        submitTrimsBodyAndPreservesMode()
        submitRejectsEmptyBody()
        labelsDescribeAddAndEditModes()
        print("QuestCommentComposerTests: all tests passed")
    }

    private static func submitTrimsBodyAndPreservesMode() {
        var composer = QuestCommentComposerModel(mode: .add(anchor: "gate:review"), body: "  first line\nsecond line  ")
        let submit = composer.submit()
        expect(submit == QuestCommentComposerSubmit(mode: .add(anchor: "gate:review"), body: "first line\nsecond line"), "add submit mismatch")
        expect(composer.errorMessage == nil, "valid submit should clear error")

        composer = QuestCommentComposerModel(mode: .edit(commentID: "comment-1"), body: "\nupdated\n")
        expect(
            composer.submit() == QuestCommentComposerSubmit(mode: .edit(commentID: "comment-1"), body: "updated"),
            "edit submit mismatch"
        )
    }

    private static func submitRejectsEmptyBody() {
        var composer = QuestCommentComposerModel(mode: .add(anchor: "quest"), body: " \n\t ")
        expect(composer.submit() == nil, "blank body should not submit")
        expect(composer.errorMessage == "comment body is empty", "blank body error mismatch")
    }

    private static func labelsDescribeAddAndEditModes() {
        let add = QuestCommentComposerModel(mode: .add(anchor: "related:plan"))
        expect(add.title == "Add comment", "add title mismatch")
        expect(add.targetLabel == "related:plan", "add target mismatch")

        let edit = QuestCommentComposerModel(mode: .edit(commentID: "comment-1"))
        expect(edit.title == "Edit comment", "edit title mismatch")
        expect(edit.targetLabel == "comment-1", "edit target mismatch")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("QuestCommentComposerTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
