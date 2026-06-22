import Foundation
import QuestmasterCore

struct QuestDetailCursorTests {
    static func run() {
        targetsFollowRenderedOrderAndSkipResolvedComments()
        movementMovesSelectionAndClamps()
        visibleRangeSelectsFirstVisibleTarget()
        actionsApplyOnlyToMatchingFocusedTargets()
        commentAddAnchorsFollowFocusedTarget()
        print("QuestDetailCursorTests: all tests passed")
    }

    private static func targetsFollowRenderedOrderAndSkipResolvedComments() {
        let quest = sampleQuest()
        let targets = QuestDetailCursorLogic.targets(in: quest)

        expect(
            targets.map(\.kind) == [.quest, .comment, .gate, .gate, .comment, .related, .comment, .related],
            "target kinds were \(targets.map(\.kind))"
        )
        expect(
            targets.map(\.id) == ["quest", "comment-quest", "auto-check", "reviewed", "comment-gate", "plan", "comment-related", "related-1"],
            "target ids were \(targets.map(\.id))"
        )
        expect(targets.map(\.anchor) == ["quest", "quest", "gate:auto-check", "gate:reviewed", "gate:reviewed", "related:plan", "related:plan", ""], "target anchors were \(targets.map(\.anchor))")
        expect(targets[2].index == 0 && targets[3].index == 1, "gate indexes should point into quest.gates")
        expect(targets[5].index == 0 && targets[7].index == 1, "related indexes should point into quest.related")
        expect(targets[1].index == 0 && targets[4].index == 1 && targets[6].index == 2, "comment indexes should point into quest.comments")
    }

    private static func movementMovesSelectionAndClamps() {
        expect(QuestDetailCursorLogic.validFocusIndex(nil, targetCount: 3) == 0, "nil focus should start on first target")
        expect(QuestDetailCursorLogic.validFocusIndex(9, targetCount: 3) == 2, "focus should clamp to last target")
        expect(QuestDetailCursorLogic.validFocusIndex(0, targetCount: 0) == nil, "empty target list should have no focus")

        expect(QuestDetailCursorLogic.move(focusIndex: 0, targetCount: 3, delta: 1) == .moved(1), "down should advance focus")
        expect(QuestDetailCursorLogic.move(focusIndex: 1, targetCount: 3, delta: -1) == .moved(0), "up should move focus back")
        expect(QuestDetailCursorLogic.move(focusIndex: 2, targetCount: 3, delta: 1) == .moved(2), "down at end should clamp")
        expect(QuestDetailCursorLogic.move(focusIndex: 0, targetCount: 3, delta: -1) == .moved(0), "up at start should clamp")
        expect(QuestDetailCursorLogic.move(focusIndex: 0, targetCount: 1, delta: 1) == .moved(0), "single target should stay selected")
        expect(QuestDetailCursorLogic.move(focusIndex: nil, targetCount: 3, delta: 0) == .moved(0), "nil focus should resolve to first target")
        expect(QuestDetailCursorLogic.move(focusIndex: nil, targetCount: 0, delta: 1) == .scroll, "empty target list should scroll")
    }

    private static func visibleRangeSelectsFirstVisibleTarget() {
        let ranges = [
            NSRange(location: 10, length: 8),
            NSRange(location: 30, length: 8),
            NSRange(location: 50, length: 8),
        ]

        expect(
            QuestDetailCursorLogic.visibleFocusIndex(targetRanges: ranges, visibleRange: NSRange(location: 0, length: 20)) == 0,
            "visible range before first target should focus first target"
        )
        expect(
            QuestDetailCursorLogic.visibleFocusIndex(targetRanges: ranges, visibleRange: NSRange(location: 18, length: 20)) == 1,
            "visible range after first target should focus second target"
        )
        expect(
            QuestDetailCursorLogic.visibleFocusIndex(targetRanges: ranges, visibleRange: NSRange(location: 99, length: 20)) == 2,
            "visible range after all targets should focus last target"
        )
        expect(
            QuestDetailCursorLogic.visibleFocusIndex(targetRanges: [], visibleRange: NSRange(location: 0, length: 20)) == nil,
            "empty rendered target list should not focus"
        )
    }

    private static func actionsApplyOnlyToMatchingFocusedTargets() {
        let quest = sampleQuest()
        let targets = QuestDetailCursorLogic.targets(in: quest)
        let autoGate = targets[2]
        let toggleGate = targets[3]
        let comment = targets[4]
        let relatedWithoutURL = targets[5]
        let relatedWithURL = targets[7]

        expect(QuestDetailCursorLogic.action(.gateToggle, focusedTarget: autoGate, in: quest) == nil, "auto gate should not emit a toggle mutation")
        expect(
            QuestDetailCursorLogic.action(.gateToggle, focusedTarget: toggleGate, in: quest) == .gateToggle(gate: "reviewed"),
            "toggle gate action mismatch"
        )
        expect(
            QuestDetailCursorLogic.action(.commentEdit, focusedTarget: comment, in: quest) == .commentEdit(commentID: "comment-gate", body: "Gate comment."),
            "comment edit action should include current body"
        )
        expect(
            QuestDetailCursorLogic.action(.commentDelete, focusedTarget: comment, in: quest) == .commentDelete(commentID: "comment-gate"),
            "comment delete action mismatch"
        )
        expect(
            QuestDetailCursorLogic.action(.commentResolve, focusedTarget: comment, in: quest) == .commentResolve(commentID: "comment-gate"),
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
            QuestDetailCursorLogic.commentAddAnchor(focusedTarget: targets[0], in: quest) == "quest",
            "quest target should add quest comment"
        )
        expect(
            QuestDetailCursorLogic.commentAddAnchor(focusedTarget: targets[3], in: quest) == "gate:reviewed",
            "gate comment anchor mismatch"
        )
        expect(
            QuestDetailCursorLogic.commentAddAnchor(focusedTarget: targets[5], in: quest) == "related:plan",
            "related comment anchor mismatch"
        )
        expect(
            QuestDetailCursorLogic.commentAddAnchor(focusedTarget: targets[7], in: quest) == "quest",
            "unanchored related should fall back to quest anchor"
        )
        expect(
            QuestDetailCursorLogic.commentAddAnchor(focusedTarget: targets[1], in: quest) == nil,
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
                    id: "comment-quest",
                    anchor: CommentAnchor(kind: "quest"),
                    status: "open",
                    author: "codex",
                    body: "Please tighten this.",
                    createdAt: "2026-06-21T00:00:00Z"
                ),
                QuestComment(
                    id: "comment-gate",
                    anchor: CommentAnchor(kind: "gate", id: "reviewed"),
                    status: "open",
                    author: "codex",
                    body: "Gate comment.",
                    createdAt: "2026-06-21T00:01:00Z"
                ),
                QuestComment(
                    id: "comment-related",
                    anchor: CommentAnchor(kind: "related", id: "plan"),
                    status: "open",
                    author: "codex",
                    body: "Related comment.",
                    createdAt: "2026-06-21T00:02:00Z"
                ),
                QuestComment(
                    id: "comment-resolved",
                    anchor: CommentAnchor(kind: "quest"),
                    status: "resolved",
                    author: "codex",
                    body: "Already done.",
                    createdAt: "2026-06-21T00:03:00Z"
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
