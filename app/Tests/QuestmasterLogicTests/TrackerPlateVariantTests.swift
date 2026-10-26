import Foundation
import QuestmasterCore

struct TrackerPlateVariantTests {
    static func run() {
        mastersUseTheTopLevelPlate()
        workersUseTheWorkerPlate()
        shellRowsDrawNoPlate()
        print("TrackerPlateVariantTests: all tests passed")
    }

    private static func mastersUseTheTopLevelPlate() {
        expect(TrackerPlateVariant(role: .master) == .topLevel, "master should use the top-level plate")
    }

    private static func workersUseTheWorkerPlate() {
        expect(TrackerPlateVariant(role: .worker) == .worker, "worker should use the worker plate")
    }

    /// Whatever the shell section takes has no plate, so the two never disagree about a row.
    private static func shellRowsDrawNoPlate() {
        for role in SessionRoleKind.allCases {
            let session = TrackerSession(id: "s", title: "s", repoName: "r", role: role.rawValue)
            expect(
                (TrackerPlateVariant(role: role) == nil) == TrackerShellSection.isShellRow(session),
                "\(role) should draw a plate exactly when it is not a shell-section row"
            )
        }
        for role in [SessionRoleKind.shell, .tmux, .orphan] {
            expect(TrackerPlateVariant(role: role) == nil, "\(role) should have no plate")
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fatalError(message)
        }
    }
}
