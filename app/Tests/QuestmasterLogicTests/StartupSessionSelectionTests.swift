import Foundation
import QuestmasterCore

struct StartupSessionSelectionTests {
    static func run() {
        startupTargetPrecedence()
        print("StartupSessionSelectionTests: all tests passed")
    }

    private static let sessions = [
        QuestmasterTmuxSession(created: 10, name: "qm-old"),
        QuestmasterTmuxSession(created: 30, name: "qm-newest"),
        QuestmasterTmuxSession(created: 20, name: "qm-remembered"),
    ]

    private static func startupTargetPrecedence() {
        let cases: [(name: String, cli: String?, env: String?, remembered: String?, expected: String?)] = [
            ("remembered live before newest", nil, nil, " qm-remembered ", "qm-remembered"),
            ("missing remembered falls back to newest", nil, nil, "qm-missing", "qm-newest"),
            ("--session wins", "custom-cli", nil, "qm-remembered", "custom-cli"),
            ("env wins", nil, "custom-env", "qm-remembered", "custom-env"),
            ("--session wins before env", "custom-cli", "custom-env", "qm-remembered", "custom-cli"),
        ]

        for testCase in cases {
            let selected = TmuxStartupSessionSelection.targetSessionID(
                commandLineSession: testCase.cli,
                environmentSession: testCase.env,
                rememberedSessionID: testCase.remembered,
                availableSessions: sessions
            )
            expect(selected == testCase.expected, "\(testCase.name): got \(selected ?? "nil")")
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("StartupSessionSelectionTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
