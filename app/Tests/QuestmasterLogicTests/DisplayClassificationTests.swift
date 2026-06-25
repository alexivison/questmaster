import Foundation
import QuestmasterCore

struct DisplayClassificationTests {
    static func run() {
        agentKindParsesKnownNamesAndFallsBack()
        sessionRoleKindParsesAliasesAndFallsBack()
        questStatusKindParsesKnownStatuses()
        classificationIsCaseAndWhitespaceInsensitive()
        print("DisplayClassificationTests: all tests passed")
    }

    private static func agentKindParsesKnownNamesAndFallsBack() {
        expect(AgentKind(name: "claude") == .claude, "claude mismatch")
        expect(AgentKind(name: "codex") == .codex, "codex mismatch")
        expect(AgentKind(name: "pi") == .pi, "pi mismatch")
        expect(AgentKind(name: "omp") == .omp, "omp mismatch")
        expect(AgentKind(name: "gemini") == .unknown, "unknown agent should fall back")
        expect(AgentKind(name: "") == .unknown, "empty agent should fall back")
    }

    private static func sessionRoleKindParsesAliasesAndFallsBack() {
        expect(SessionRoleKind(role: "master") == .master, "master mismatch")
        expect(SessionRoleKind(role: "primary") == .master, "primary alias should map to master")
        expect(SessionRoleKind(role: "worker") == .worker, "worker mismatch")
        expect(SessionRoleKind(role: "tmux") == .tmux, "tmux mismatch")
        expect(SessionRoleKind(role: "orphan") == .orphan, "orphan mismatch")
        expect(SessionRoleKind(role: "freeform") == .standalone, "unknown role should be standalone")
    }

    private static func questStatusKindParsesKnownStatuses() {
        expect(QuestStatusKind(status: "active") == .active, "active mismatch")
        expect(QuestStatusKind(status: "done") == .done, "done mismatch")
        expect(QuestStatusKind(status: "blocked") == .other, "unknown status should be other")
    }

    private static func classificationIsCaseAndWhitespaceInsensitive() {
        expect(AgentKind(name: "  Claude ") == .claude, "agent should trim and lowercase")
        expect(SessionRoleKind(role: "WORKER") == .worker, "role should lowercase")
        expect(QuestStatusKind(status: " Active ") == .active, "status should trim and lowercase")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("DisplayClassificationTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
