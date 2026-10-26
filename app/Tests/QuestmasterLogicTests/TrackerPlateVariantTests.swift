import Foundation
import QuestmasterCore

struct TrackerPlateVariantTests {
    static func run() {
        mastersUseTheTopLevelPlate()
        workersUseTheWorkerPlate()
        print("TrackerPlateVariantTests: all tests passed")
    }

    private static func mastersUseTheTopLevelPlate() {
        expect(TrackerPlateVariant(role: .master) == .topLevel, "master should use the top-level plate")
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
