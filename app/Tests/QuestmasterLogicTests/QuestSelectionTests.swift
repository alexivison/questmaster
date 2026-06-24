import Foundation
import QuestmasterCore

struct QuestSelectionTests {
    static func run() {
        selectedQuestUsesFreshActiveQuestOverStaleBoardCopy()
        selectedQuestCanSwitchBackFromActiveFallback()
        print("QuestSelectionTests: all tests passed")
    }

    private static func selectedQuestUsesFreshActiveQuestOverStaleBoardCopy() {
        let stale = quest(id: "Q-1", title: "Board copy", comments: [])
        let fresh = quest(
            id: "Q-1",
            title: "Fresh active copy",
            comments: [
                QuestComment(
                    id: "c-1",
                    anchor: CommentAnchor(kind: "body", id: "intro"),
                    status: "open",
                    author: "bench",
                    body: "fresh comment",
                    createdAt: "2026-06-22T00:00:00Z"
                ),
            ]
        )
        let board = BoardSnapshot(repos: [
            QuestRepo(id: "repo", name: "repo", quests: [stale]),
        ])

        let selected = QuestSelectionResolver.selectedQuest(
            id: "Q-1",
            board: board,
            activeQuest: fresh,
            fallbackQuest: stale
        )

        expect(selected?.title == "Fresh active copy", "selected quest should use active quest payload")
        expect(selected?.commentCount == 1, "selected quest should include fresh active quest comments")
    }

    private static func selectedQuestCanSwitchBackFromActiveFallback() {
        let first = quest(id: "Q-1", title: "First quest", comments: [])
        let second = quest(id: "Q-2", title: "Second quest", comments: [])
        let activeSecond = quest(id: "Q-2", title: "Fresh active second", comments: [])
        let board = BoardSnapshot(repos: [
            QuestRepo(id: "repo", name: "repo", quests: [first, second]),
        ])

        let selectedSecond = QuestSelectionResolver.selectedQuest(
            id: "Q-2",
            board: board,
            activeQuest: activeSecond,
            fallbackQuest: activeSecond
        )
        let selectedFirst = QuestSelectionResolver.selectedQuest(
            id: "Q-1",
            board: board,
            activeQuest: activeSecond,
            fallbackQuest: activeSecond
        )

        expect(selectedSecond?.title == "Fresh active second", "active quest should be used for matching second selection")
        expect(selectedFirst?.title == "First quest", "switching back should resolve the board quest instead of active fallback")
    }

    private static func quest(id: String, title: String, comments: [QuestComment]) -> QuestDocument {
        QuestDocument(
            id: id,
            title: title,
            status: "active",
            summary: "",
            date: "2026-06-22",
            project: "repo",
            related: [],
            gates: [],
            body: [],
            comments: comments,
            runtime: QuestRuntime()
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("QuestSelectionTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
