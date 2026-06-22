import Foundation
import QuestmasterCore

struct QuestDetailCursorTests {
    static func run() {
        targetsFollowRenderedOrderAndSkipResolvedComments()
        movementFallsBackToScrollAtEdges()
        actionsApplyOnlyToMatchingFocusedTargets()
        commentAddAnchorsFollowFocusedTarget()
        print("QuestDetailCursorTests: all tests passed")
    }

    private static func targetsFollowRenderedOrderAndSkipResolvedComments() {
        let quest = sampleQuest()
        let targets = QuestDetailCursorLogic.targets(in: quest)

        expect(
            targets.map(\.kind) == [.gate, .gate, .related, .related, .comment],
            "target kinds were \(targets.map(\.kind))"
        )
        expect(targets.map(\.id) == ["auto-check", "reviewed", "plan", "related-1", "comment-1"], "target ids were \(targets.map(\.id))")
        expect(targets[0].index == 0 && targets[1].index == 1, "gate indexes should point into quest.gates")
        expect(targets[2].index == 0 && targets[3].index == 1, "related indexes should point into quest.related")
        expect(targets[4].index == 0, "comment index should point into quest.comments")
    }

    private static func movementFallsBackToScrollAtEdges() {
        expect(QuestDetailCursorLogic.validFocusIndex(nil, targetCount: 3) == 0, "nil focus should start on first target")
        expect(QuestDetailCursorLogic.validFocusIndex(9, targetCount: 3) == 2, "focus should clamp to last target")
        expect(QuestDetailCursorLogic.validFocusIndex(0, targetCount: 0) == nil, "empty target list should have no focus")

        expect(QuestDetailCursorLogic.move(focusIndex: 0, targetCount: 3, delta: 1) == .moved(1), "down should move to next target")
        expect(QuestDetailCursorLogic.move(focusIndex: 1, targetCount: 3, delta: -1) == .moved(0), "up should move to previous target")
        expect(QuestDetailCursorLogic.move(focusIndex: 2, targetCount: 3, delta: 1) == .scroll, "down at end should scroll")
        expect(QuestDetailCursorLogic.move(focusIndex: 0, targetCount: 3, delta: -1) == .scroll, "up at start should scroll")
        expect(QuestDetailCursorLogic.move(focusIndex: 0, targetCount: 1, delta: 1) == .scroll, "single target should scroll")
        expect(QuestDetailCursorLogic.move(focusIndex: nil, targetCount: 0, delta: 1) == .scroll, "empty target list should scroll")
    }

    private static func actionsApplyOnlyToMatchingFocusedTargets() {
        let quest = sampleQuest()
        let targets = QuestDetailCursorLogic.targets(in: quest)
        let autoGate = targets[0]
        let toggleGate = targets[1]
        let relatedWithoutURL = targets[2]
        let relatedWithURL = targets[3]
        let comment = targets[4]

        expect(QuestDetailCursorLogic.action(.gateToggle, focusedTarget: autoGate, in: quest) == nil, "auto gate should not emit a toggle mutation")
        expect(
            QuestDetailCursorLogic.action(.gateToggle, focusedTarget: toggleGate, in: quest) == .gateToggle(gate: "reviewed"),
            "toggle gate action mismatch"
        )
        expect(
            QuestDetailCursorLogic.action(.commentEdit, focusedTarget: comment, in: quest) == .commentEdit(commentID: "comment-1", body: "Please tighten this."),
            "comment edit action should include current body"
        )
        expect(
            QuestDetailCursorLogic.action(.commentDelete, focusedTarget: comment, in: quest) == .commentDelete(commentID: "comment-1"),
            "comment delete action mismatch"
        )
        expect(
            QuestDetailCursorLogic.action(.commentResolve, focusedTarget: comment, in: quest) == .commentResolve(commentID: "comment-1"),
            "comment resolve action mismatch"
        )
        expect(QuestDetailCursorLogic.action(.openRelated, focusedTarget: relatedWithoutURL, in: quest) == nil, "related link without URL should no-op")
        expect(
            QuestDetailCursorLogic.action(.openRelated, focusedTarget: relatedWithURL, in: quest) == .openRelated(url: "https://example.com/plan"),
            "related open action mismatch"
        )
        expect(QuestDetailCursorLogic.action(.commentEdit, focusedTarget: toggleGate, in: quest) == nil, "wrong target type should no-op")
    }

    private static func commentAddAnchorsFollowFocusedTarget() {
        let quest = sampleQuest()
        let targets = QuestDetailCursorLogic.targets(in: quest)

        expect(QuestDetailCursorLogic.commentAddAnchor(focusedTarget: nil, in: quest) == "quest", "nil focus should add quest comment")
        expect(
            QuestDetailCursorLogic.commentAddAnchor(focusedTarget: targets[1], in: quest) == "gate:reviewed",
            "gate comment anchor mismatch"
        )
        expect(
            QuestDetailCursorLogic.commentAddAnchor(focusedTarget: targets[2], in: quest) == "related:plan",
            "related comment anchor mismatch"
        )
        expect(
            QuestDetailCursorLogic.commentAddAnchor(focusedTarget: targets[3], in: quest) == "quest",
            "unanchored related should fall back to quest anchor"
        )
        expect(
            QuestDetailCursorLogic.commentAddAnchor(focusedTarget: targets[4], in: quest) == nil,
            "focused comment should not open add composer"
        )
    }

    private static func sampleQuest() -> QuestDocument {
        QuestDocument(
            id: "Q-CURSOR",
            title: "Cursor quest",
            status: "active",
            summary: "Exercise cursor logic.",
            date: "",
            project: "",
            related: [
                RelatedLink(id: "plan", type: "doc", title: "Plan", url: ""),
                RelatedLink(id: "", type: "doc", title: "Fallback related", url: "https://example.com/plan"),
            ],
            gates: [
                QuestGate(name: "auto-check", type: "auto"),
                QuestGate(name: "reviewed", type: "toggle"),
            ],
            body: [],
            comments: [
                QuestComment(
                    id: "comment-1",
                    anchor: CommentAnchor(kind: "quest"),
                    status: "open",
                    author: "codex",
                    body: "Please tighten this.",
                    createdAt: "2026-06-21T00:00:00Z"
                ),
                QuestComment(
                    id: "comment-2",
                    anchor: CommentAnchor(kind: "quest"),
                    status: "resolved",
                    author: "codex",
                    body: "Already done.",
                    createdAt: "2026-06-21T00:01:00Z"
                ),
            ],
            runtime: QuestRuntime()
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("QuestDetailCursorTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
