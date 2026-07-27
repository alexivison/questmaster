import Foundation
import QuestmasterCore

struct DestructiveConfirmationTests {
    static func run() {
        deleteSessionCopyIsExplicit()
        deleteArtifactKeepsTheFile()
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

    private static func deleteArtifactKeepsTheFile() {
        let spec = DestructiveConfirmation.deleteArtifact(ArtifactReference(
            kind: "html",
            path: "/tmp/plan.html",
            label: " Plan ",
            sessionID: "qm-worker",
            addedAt: ""
        ))
        expect(spec.action == .deleteArtifact, "action mismatch")
        expect(spec.subjectID == "/tmp/plan.html", "artifact path mismatch")
        expect(spec.title == "Delete artifact Plan?", "title mismatch: \(spec.title)")
        expect(spec.message == "This removes it from the artifact list. The file stays on disk.", "message mismatch: \(spec.message)")
        expect(spec.confirmLabel == "Remove", "confirm label mismatch")
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
