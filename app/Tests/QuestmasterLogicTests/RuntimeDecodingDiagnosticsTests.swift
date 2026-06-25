import Foundation
import QuestmasterCore

struct RuntimeDecodingDiagnosticsTests {
    static func run() {
        skippedLossyArrayItemsAreCounted()
        cleanPayloadDoesNotRecordSkips()
        print("RuntimeDecodingDiagnosticsTests: all tests passed")
    }

    private static func skippedLossyArrayItemsAreCounted() {
        RuntimeDecodingDiagnostics.reset()
        // The gates array is lossy-decoded; the bad element should be skipped, not fatal.
        let raw = """
        {"id":"Q-DIAG","title":"Diag quest","status":"active","summary":"x","gates":[{"name":"ok","type":"toggle","checked":true},"not-a-gate"]}
        """
        do {
            let quest = try JSONDecoder().decode(QuestDocument.self, from: Data(raw.utf8))
            expect(quest.gates.count == 1, "valid gate should still decode when a sibling is bad")
        } catch {
            fail("quest with one bad gate should still decode, threw \(error)")
        }
        expect(RuntimeDecodingDiagnostics.skippedItemCount >= 1, "skipped lossy item was not counted")
    }

    private static func cleanPayloadDoesNotRecordSkips() {
        RuntimeDecodingDiagnostics.reset()
        let raw = """
        {"id":"Q-CLEAN","title":"Clean quest","status":"active","summary":"x","gates":[{"name":"ok","type":"toggle","checked":true}]}
        """
        do {
            _ = try JSONDecoder().decode(QuestDocument.self, from: Data(raw.utf8))
        } catch {
            fail("clean quest should decode, threw \(error)")
        }
        expect(RuntimeDecodingDiagnostics.skippedItemCount == 0, "clean payload should not record skips")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fail(message)
        }
    }

    private static func fail(_ message: String) -> Never {
        fputs("RuntimeDecodingDiagnosticsTests failed: \(message)\n", stderr)
        Foundation.exit(1)
    }
}
