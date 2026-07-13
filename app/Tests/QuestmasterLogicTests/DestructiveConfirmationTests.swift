import Foundation
import QuestmasterCore

struct DestructiveConfirmationTests {
    static func run() {
        deleteSessionCopyIsExplicit()
        keyDecisionsAreCaseInsensitive()
        print("DestructiveConfirmationTests: all tests passed")
    }

    private static func deleteSessionCopyIsExplicit() {
        let spec = DestructiveConfirmation.deleteSession(sessionID: " qm-worker ")
        expect(spec.action == .deleteSession, "action mismatch")
        expect(spec.subjectID == "qm-worker", "subject should be trimmed")
        expect(spec.title == "Delete session qm-worker?", "title mismatch: \(spec.title)")
        expect(spec.message == "qm-worker will be lost to the void. This can't be undone.", "message mismatch: \(spec.message)")
        expect(spec.confirmLabel == "Banish", "confirm label mismatch")
    }

    private static func keyDecisionsAreCaseInsensitive() {
        expect(DestructiveConfirmationDecision.key("y") == .confirm, "y should confirm")
        expect(DestructiveConfirmationDecision.key("Y") == .confirm, "Y should confirm")
        expect(DestructiveConfirmationDecision.key("\r") == .confirm, "return should confirm")
        expect(DestructiveConfirmationDecision.key("\u{1b}") == .cancel, "escape should cancel")
        expect(DestructiveConfirmationDecision.key("n") == .cancel, "n should cancel")
        expect(DestructiveConfirmationDecision.key("x") == nil, "x should be ignored")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fail(message)
        }
    }

    private static func fail(_ message: String) -> Never {
        fputs("DestructiveConfirmationTests failed: \(message)\n", stderr)
        Foundation.exit(1)
    }
}
