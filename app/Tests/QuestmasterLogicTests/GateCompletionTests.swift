import Foundation
import QuestmasterCore

struct GateCompletionTests {
    static func run() {
        observedStatusesAndToggleGatesDriveProgress()
        print("GateCompletionTests: all tests passed")
    }

    private static func observedStatusesAndToggleGatesDriveProgress() {
        let passed = QuestGate(name: "build", type: "auto")
        let failed = QuestGate(name: "lint", type: "auto")
        let checked = QuestGate(name: "reviewed", type: "toggle", checked: true)
        let unchecked = QuestGate(name: "mocks", type: "toggle", checked: false)
        let runtime = QuestRuntime(gates: [
            "build": " PASS ",
            "lint": "failed",
            "reviewed": "failed",
            "mocks": "pass",
        ])

        expect(QuestGateCompletion.isComplete(passed, runtime: runtime), "whitespace/case pass status was not complete")
        expect(QuestGateCompletion.isComplete(QuestGate(name: "done", type: "auto"), observed: "Completed"), "completed status was not complete")
        expect(!QuestGateCompletion.isComplete(failed, runtime: runtime), "failed auto gate was complete")
        expect(QuestGateCompletion.isComplete(checked, runtime: runtime), "checked toggle gate was not complete")
        expect(!QuestGateCompletion.isComplete(unchecked, runtime: runtime), "unchecked toggle gate was complete")

        let progress = QuestGateCompletion.progress(gates: [passed, failed, checked, unchecked], runtime: runtime)
        expect(progress == QuestGateProgressCounts(completed: 2, total: 4), "progress was \(progress.completed)/\(progress.total)")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("GateCompletionTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
