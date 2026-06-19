import Foundation
import QuestmasterAppCore

struct MutationRequestTests {
    static func run() {
        questGateToggleEncodesQuestIDAndGate()
        relayRejectsBlankMessage()
        spawnTrimsOptionalFields()
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
