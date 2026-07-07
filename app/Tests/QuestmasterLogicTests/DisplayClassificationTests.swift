import Foundation
import QuestmasterCore

struct DisplayClassificationTests {
    static func run() {
        agentKindParsesKnownNamesAndFallsBack()
        agentDisplayNameCapitalizesKnownAndUnknown()
        agentKindParsesShellSessions()
        sessionRoleKindParsesAliasesAndFallsBack()
        sessionActivityStatusKindParsesKnownStatuses()
        classificationIsCaseAndWhitespaceInsensitive()
        print("DisplayClassificationTests: all tests passed")
    }

    private static func agentKindParsesKnownNamesAndFallsBack() {
        expect(AgentKind(name: "claude") == .claude, "claude mismatch")
        expect(AgentKind(name: "codex") == .codex, "codex mismatch")
        expect(AgentKind(name: "opencode") == .opencode, "opencode mismatch")
        expect(AgentKind(name: "pi") == .pi, "pi mismatch")
        expect(AgentKind(name: "gemini") == .unknown, "unknown agent should fall back")
    }

    private static func agentDisplayNameCapitalizesKnownAndUnknown() {
        expect(AgentKind.displayName(for: "claude") == "Claude", "claude display mismatch")
        expect(AgentKind.displayName(for: "codex") == "Codex", "codex display mismatch")
        expect(AgentKind.displayName(for: "opencode") == "OpenCode", "opencode display mismatch")
        expect(AgentKind.displayName(for: "pi") == "Pi", "pi display mismatch")
        expect(AgentKind.displayName(for: "  Claude ") == "Claude", "display should trim/normalize")
        expect(AgentKind.displayName(for: "gemini") == "Gemini", "unknown agent should capitalize first letter")
        expect(AgentKind.displayName(for: "") == "Shell", "empty agent should display as Shell")
    }

    private static func agentKindParsesShellSessions() {
        expect(AgentKind(name: "") == .shell, "empty agent should be shell")
        expect(AgentKind(name: " shell ") == .shell, "shell agent should parse")
        expect(AgentKind.displayName(for: "shell") == "Shell", "shell display mismatch")
    }

    private static func sessionRoleKindParsesAliasesAndFallsBack() {
        expect(SessionRoleKind(role: "master") == .master, "master mismatch")
        expect(SessionRoleKind(role: "primary") == .master, "primary alias should map to master")
        expect(SessionRoleKind(role: "worker") == .worker, "worker mismatch")
        expect(SessionRoleKind(role: "tmux") == .tmux, "tmux mismatch")
        expect(SessionRoleKind(role: "orphan") == .orphan, "orphan mismatch")
        expect(SessionRoleKind(role: "freeform") == .standalone, "unknown role should be standalone")
    }

    private static func sessionActivityStatusKindParsesKnownStatuses() {
        expect(SessionActivityStatusKind(status: "working") == .working, "working mismatch")
        expect(SessionActivityStatusKind(status: "starting") == .working, "starting should map to working")
        expect(SessionActivityStatusKind(status: "checking") == .working, "checking should map to working")
        expect(SessionActivityStatusKind(status: "blocked") == .blocked, "blocked mismatch")
        expect(SessionActivityStatusKind(status: "error") == .blocked, "error should map to blocked")
        expect(SessionActivityStatusKind(status: "failed") == .blocked, "failed should map to blocked")
        expect(SessionActivityStatusKind(status: "fail") == .blocked, "fail should map to blocked")
        expect(SessionActivityStatusKind(status: "done") == .done, "done mismatch")
        expect(SessionActivityStatusKind(status: "pass") == .done, "pass should map to done")
        expect(SessionActivityStatusKind(status: "passed") == .done, "passed should map to done")
        expect(SessionActivityStatusKind(status: "ok") == .done, "ok should map to done")
        expect(SessionActivityStatusKind(status: "stopped") == .stopped, "stopped mismatch")
        expect(SessionActivityStatusKind(status: "idle") == .other, "unknown status should be other")
        expect(SessionActivityStatusKind(status: "") == .other, "empty status should be other")
        expect(SessionActivityStatusKind(status: " Working ") == .working, "status should trim and lowercase")
    }

    private static func classificationIsCaseAndWhitespaceInsensitive() {
        expect(AgentKind(name: "  Claude ") == .claude, "agent should trim and lowercase")
        expect(SessionRoleKind(role: "WORKER") == .worker, "role should lowercase")
        expect(SessionActivityStatusKind(status: " Working ") == .working, "status should trim and lowercase")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("DisplayClassificationTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
