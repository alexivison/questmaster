import Foundation
import QuestmasterCore

struct QuestCommandLogicTests {
    static func run() {
        viewerCommandsBuildMutationEffects()
        destructiveViewerCommandsRequireConfirmation()
        deleteQuestRequiresConfirmation()
        openRelatedStaysASeparateEffect()
        print("QuestCommandLogicTests: all tests passed")
    }

    private static func viewerCommandsBuildMutationEffects() {
        let quest = testQuest()

        do {
            let gateToggle = try QuestCommandLogic.effect(for: .gateToggle(gate: " review "), quest: quest)
            let expectedGateToggle = QuestCommandEffect.mutation(
                try ServeMutationRequests.questGateToggle(questID: quest.id, gate: " review "),
                label: "toggle  review "
            )
            expect(
                gateToggle == expectedGateToggle,
                "gate toggle effect mismatch"
            )
            let commentAdd = try QuestCommandLogic.effect(for: .commentAdd(anchor: "quest", body: " ship it "), quest: quest)
            let expectedCommentAdd = QuestCommandEffect.mutation(
                try ServeMutationRequests.questCommentAdd(questID: quest.id, anchor: "quest", body: " ship it "),
                label: "comment DEMO-1"
            )
            expect(
                commentAdd == expectedCommentAdd,
                "comment add effect mismatch"
            )
            let approve = try QuestCommandLogic.effect(for: .approve, quest: quest)
            let expectedApprove = QuestCommandEffect.mutation(
                try ServeMutationRequests.questStatus(questID: quest.id, status: "active"),
                label: "approve DEMO-1"
            )
            expect(
                approve == expectedApprove,
                "approve effect mismatch"
            )
            let withdraw = try QuestCommandLogic.effect(for: .withdraw, quest: quest)
            let expectedWithdraw = QuestCommandEffect.mutation(
                try ServeMutationRequests.questStatus(questID: quest.id, status: "wip"),
                label: "withdraw DEMO-1"
            )
            expect(
                withdraw == expectedWithdraw,
                "withdraw effect mismatch"
            )
        } catch {
            fail("viewer command effect threw \(error)")
        }
    }

    private static func destructiveViewerCommandsRequireConfirmation() {
        let quest = testQuest()

        do {
            let commentDelete = try QuestCommandLogic.effect(for: .commentDelete(commentID: " comment-1 "), quest: quest)
            let expectedCommentDelete = QuestCommandEffect.confirmedMutation(
                DestructiveConfirmation.deleteComment(questID: quest.id, commentID: " comment-1 "),
                request: try ServeMutationRequests.questCommentDelete(questID: quest.id, commentID: " comment-1 "),
                label: "delete comment  comment-1 "
            )
            expect(
                commentDelete == expectedCommentDelete,
                "comment delete confirmation mismatch"
            )
            let done = try QuestCommandLogic.effect(for: .done, quest: quest)
            let expectedDone = QuestCommandEffect.confirmedMutation(
                DestructiveConfirmation.markQuestDone(questID: quest.id, title: quest.title),
                request: try ServeMutationRequests.questStatus(questID: quest.id, status: "done"),
                label: "done DEMO-1"
            )
            expect(
                done == expectedDone,
                "done confirmation mismatch"
            )
        } catch {
            fail("destructive viewer command effect threw \(error)")
        }
    }

    private static func deleteQuestRequiresConfirmation() {
        let quest = testQuest()

        do {
            let deleteQuest = try QuestCommandLogic.deleteQuestEffect(quest)
            let expectedDeleteQuest = QuestCommandEffect.confirmedMutation(
                DestructiveConfirmation.deleteQuest(questID: quest.id, title: quest.title),
                request: try ServeMutationRequests.questDelete(questID: quest.id),
                label: "delete quest DEMO-1"
            )
            expect(
                deleteQuest == expectedDeleteQuest,
                "quest delete confirmation mismatch"
            )
        } catch {
            fail("delete quest effect threw \(error)")
        }
    }

    private static func openRelatedStaysASeparateEffect() {
        let quest = testQuest()

        do {
            let effect = try QuestCommandLogic.effect(for: .openRelated(url: "file:///tmp/plan.html"), quest: quest)
            expect(
                effect == .openRelated("file:///tmp/plan.html"),
                "open related effect mismatch"
            )
        } catch {
            fail("open related effect threw \(error)")
        }
    }

    private static func testQuest() -> QuestDocument {
        QuestDocument(
            id: "DEMO-1",
            title: "Demo quest",
            status: "active",
            summary: "",
            date: "",
            project: "repo",
            related: [],
            gates: [],
            body: [],
            comments: [],
            runtime: QuestRuntime()
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fail(message)
        }
    }

    private static func fail(_ message: String) -> Never {
        fputs("QuestCommandLogicTests failed: \(message)\n", stderr)
        Foundation.exit(1)
    }
}
