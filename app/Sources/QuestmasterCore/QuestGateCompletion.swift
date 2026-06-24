import Foundation

public struct QuestGateProgressCounts: Equatable {
    public let completed: Int
    public let total: Int

    public init(completed: Int, total: Int) {
        self.completed = completed
        self.total = total
    }
}

public enum QuestGateCompletion {
    private static let passingStatuses: Set<String> = [
        "pass",
        "passed",
        "ok",
        "done",
        "complete",
        "completed",
    ]

    public static func isComplete(_ gate: QuestGate, runtime: QuestRuntime) -> Bool {
        isComplete(gate, observed: runtime.gates[gate.name] ?? "")
    }

    public static func isComplete(_ gate: QuestGate, observed: String) -> Bool {
        if gate.type == "toggle" {
            return gate.checked
        }
        return passingStatuses.contains(
            observed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
    }

    public static func progress(gates: [QuestGate], runtime: QuestRuntime) -> QuestGateProgressCounts {
        QuestGateProgressCounts(
            completed: gates.filter { isComplete($0, runtime: runtime) }.count,
            total: gates.count
        )
    }
}
