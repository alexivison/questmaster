import Foundation
import QuestmasterCore

struct TrackerPlateVariantTests {
    static func run() {
        masterAndShellShareTheTopLevelPlate()
        workersUseTheWorkerPlate()
        print("TrackerPlateVariantTests: all tests passed")
    }

    private static func masterAndShellShareTheTopLevelPlate() {
        expect(TrackerPlateVariant(role: .master) == .topLevel, "master should use the top-level plate")
        expect(TrackerPlateVariant(role: .shell) == .topLevel, "shell should use the top-level plate")
        expect(TrackerPlateVariant(role: .tmux) == .topLevel, "tmux should use the top-level plate")
        expect(TrackerPlateVariant(role: .orphan) == .topLevel, "orphan should use the top-level plate")
    }

    private static func workersUseTheWorkerPlate() {
        expect(TrackerPlateVariant(role: .worker) == .worker, "worker should use the worker plate")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fatalError(message)
        }
    }
}
