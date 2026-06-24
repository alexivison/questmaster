import Foundation
import QuestmasterCore

struct MutationRequestTests {
    static func run() {
        questGateToggleEncodesQuestIDAndGate()
        questCommentEditEncodesQuestIDCommentIDAndBody()
        questCommentDeleteEncodesQuestIDAndCommentID()
        questCommentResolveEncodesQuestIDAndCommentID()
        questDeleteEncodesQuestID()
        relayRejectsBlankMessage()
        spawnTrimsOptionalFields()
        startTrimsOptionalFields()
        mutationFailureFeedbackNamesActionAndError()
        print("MutationRequestTests: all tests passed")
    }

    private static func questGateToggleEncodesQuestIDAndGate() {
        do {
            let request = try ServeMutationRequests.questGateToggle(questID: " DEMO-1 ", gate: " reviewed ")
            let object = request.jsonObject(id: "gate") as NSDictionary

            expect(object["id"] as? String == "gate", "id missing")
            expect(object["method"] as? String == "quest.gate_toggle", "method mismatch")
            expect(object["quest_id"] as? String == "DEMO-1", "quest id was not trimmed")
            let data = object["data"] as? NSDictionary
            expect(data?["gate"] as? String == "reviewed", "gate was not encoded")
        } catch {
            fail("quest gate request threw \(error)")
        }
    }

    private static func questDeleteEncodesQuestID() {
        do {
            let request = try ServeMutationRequests.questDelete(questID: " DEMO-2 ")
            let object = request.jsonObject(id: "delete-quest") as NSDictionary

            expect(object["method"] as? String == "quest.delete", "method mismatch")
            expect(object["quest_id"] as? String == "DEMO-2", "quest id was not trimmed")
            expect(object["data"] == nil, "quest delete should not need data")
        } catch {
            fail("quest delete request threw \(error)")
        }
    }

    private static func questCommentEditEncodesQuestIDCommentIDAndBody() {
        do {
            let request = try ServeMutationRequests.questCommentEdit(
                questID: " DEMO-1 ",
                commentID: " comment-1 ",
                body: " updated body "
            )
            let object = request.jsonObject(id: "comment-edit") as NSDictionary

            expect(object["method"] as? String == "quest.comment_edit", "method mismatch")
            expect(object["quest_id"] as? String == "DEMO-1", "quest id was not trimmed")
            let data = object["data"] as? NSDictionary
            expect(data?["comment_id"] as? String == "comment-1", "comment id was not encoded")
            expect(data?["body"] as? String == "updated body", "body was not encoded")
        } catch {
            fail("quest comment edit request threw \(error)")
        }
    }

    private static func questCommentDeleteEncodesQuestIDAndCommentID() {
        do {
            let request = try ServeMutationRequests.questCommentDelete(questID: " DEMO-1 ", commentID: " comment-1 ")
            let object = request.jsonObject(id: "comment-delete") as NSDictionary

            expect(object["method"] as? String == "quest.comment_delete", "method mismatch")
            expect(object["quest_id"] as? String == "DEMO-1", "quest id was not trimmed")
            let data = object["data"] as? NSDictionary
            expect(data?["comment_id"] as? String == "comment-1", "comment id was not encoded")
            expect(data?.count == 1, "delete should only encode comment_id")
        } catch {
            fail("quest comment delete request threw \(error)")
        }
    }

    private static func questCommentResolveEncodesQuestIDAndCommentID() {
        do {
            let request = try ServeMutationRequests.questCommentResolve(questID: " DEMO-1 ", commentID: " comment-1 ")
            let object = request.jsonObject(id: "comment-resolve") as NSDictionary

            expect(object["method"] as? String == "quest.comment_resolve", "method mismatch")
            expect(object["quest_id"] as? String == "DEMO-1", "quest id was not trimmed")
            let data = object["data"] as? NSDictionary
            expect(data?["comment_id"] as? String == "comment-1", "comment id was not encoded")
            expect(data?.count == 1, "resolve should only encode comment_id")
        } catch {
            fail("quest comment resolve request threw \(error)")
        }
    }

    private static func relayRejectsBlankMessage() {
        do {
            _ = try ServeMutationRequests.relay(workerID: "qm-worker", message: "  ")
            fail("relay accepted a blank message")
        } catch ServeMutationRequestError.missing(let field) {
            expect(field == "message", "blank relay failed on \(field)")
        } catch {
            fail("relay threw unexpected error \(error)")
        }
    }

    private static func spawnTrimsOptionalFields() {
        do {
            let request = try ServeMutationRequests.spawn(
                masterID: " qm-master ",
                title: " worker ",
                cwd: " /tmp/work ",
                prompt: "  ",
                agent: " codex ",
                questID: nil
            )
            let object = request.jsonObject(id: "spawn") as NSDictionary
            let data = object["data"] as? NSDictionary
            expect(data?["master_id"] as? String == "qm-master", "master id was not trimmed")
            expect(data?["title"] as? String == "worker", "title was not trimmed")
            expect(data?["cwd"] as? String == "/tmp/work", "cwd was not trimmed")
            expect(data?["primary"] as? String == "codex", "agent was not trimmed")
            expect(data?["prompt"] == nil, "blank prompt should be omitted")
            expect(data?["quest_id"] == nil, "nil quest should be omitted")
        } catch {
            fail("spawn request threw \(error)")
        }
    }

    private static func startTrimsOptionalFields() {
        do {
            let request = try ServeMutationRequests.start(
                role: .master,
                title: " orchestrator ",
                cwd: " /tmp/project ",
                agent: " claude ",
                color: " violet ",
                questID: " DEMO-1 ",
                prompt: "  "
            )
            let object = request.jsonObject(id: "start") as NSDictionary
            expect(object["method"] as? String == "start", "method mismatch")
            let data = object["data"] as? NSDictionary
            expect(data?["master"] as? String == "true", "master role was not encoded")
            expect(data?["title"] as? String == "orchestrator", "title was not trimmed")
            expect(data?["cwd"] as? String == "/tmp/project", "cwd was not trimmed")
            expect(data?["primary"] as? String == "claude", "agent was not encoded as primary")
            expect(data?["color"] as? String == "violet", "color was not trimmed")
            expect(data?["quest_id"] as? String == "DEMO-1", "quest id was not trimmed")
            expect(data?["prompt"] == nil, "blank prompt should be omitted")
        } catch {
            fail("start request threw \(error)")
        }
    }

    private static func mutationFailureFeedbackNamesActionAndError() {
        expect(
            MutationFailureFeedback.message(label: " delete qm-a ", errorDescription: "session not found") == "Could not delete qm-a: session not found",
            "mutation feedback should name the failed user action and serve error"
        )
        expect(
            MutationFailureFeedback.message(label: "", errorDescription: "") == "Mutation failed.",
            "mutation feedback should have a bounded fallback"
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fail(message)
        }
    }

    private static func fail(_ message: String) -> Never {
        fputs("MutationRequestTests failed: \(message)\n", stderr)
        Foundation.exit(1)
    }
}
