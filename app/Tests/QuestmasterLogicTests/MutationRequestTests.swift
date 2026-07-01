import Foundation
import QuestmasterCore

struct MutationRequestTests {
    static func run() {
        startTrimsOptionalFields()
        startOmitsNoColor()
        deleteAndSwitchEncodeSessionData()
        mutationFailureFeedbackNamesActionAndError()
        print("MutationRequestTests: all tests passed")
    }

    private static func startTrimsOptionalFields() {
        do {
            let request = try ServeMutationRequests.start(
                role: .master,
                title: " orchestrator ",
                cwd: " /tmp/project ",
                agent: " claude ",
                color: " violet ",
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
            expect(data?["prompt"] == nil, "blank prompt should be omitted")
        } catch {
            fail("start request threw \(error)")
        }
    }

    private static func startOmitsNoColor() {
        do {
            let request = try ServeMutationRequests.start(
                role: .standalone,
                title: nil,
                cwd: " /tmp/project ",
                agent: " codex ",
                color: NewSessionFormModel.noColor,
                prompt: nil
            )
            let object = request.jsonObject(id: "start-none") as NSDictionary
            let data = object["data"] as? NSDictionary
            expect(data?["cwd"] as? String == "/tmp/project", "cwd was not trimmed")
            expect(data?["primary"] as? String == "codex", "agent was not encoded")
            expect(data?["color"] == nil, "no color should be omitted")
        } catch {
            fail("no-color start request threw \(error)")
        }
    }

    private static func deleteAndSwitchEncodeSessionData() {
        do {
            let delete = try ServeMutationRequests.delete(sessionID: " qm-a ")
            let deleteData = delete.jsonObject(id: "delete")["data"] as? NSDictionary
            expect(delete.method == "delete", "delete method mismatch")
            expect(deleteData?["session_id"] as? String == "qm-a", "delete session id should be trimmed")

            let switchRequest = try ServeMutationRequests.switchSession(sessionID: " qm-b ")
            let switchData = switchRequest.jsonObject(id: "switch")["data"] as? NSDictionary
            expect(switchRequest.method == "switch", "switch method mismatch")
            expect(switchData?["session_id"] as? String == "qm-b", "switch session id should be trimmed")
        } catch {
            fail("session request threw \(error)")
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
