import Foundation
import QuestmasterCore

struct CaffeineStateTests {
    static func run() {
        labelFlipsWithState()
        argumentsDropDeadFlagAndTieToAppPID()
        print("CaffeineStateTests: all tests passed")
    }

    private static func labelFlipsWithState() {
        expect(
            CaffeineState(isActive: false).accessibilityLabel == "Keep Mac awake",
            "idle label should invite turning it on"
        )
        expect(
            CaffeineState(isActive: true).accessibilityLabel == "Stop keeping Mac awake",
            "active label should invite turning it off"
        )
    }

    private static func argumentsDropDeadFlagAndTieToAppPID() {
        let args = CaffeineState.caffeinateArguments(appPID: 4821)
        expect(args == ["-dims", "-w", "4821"], "args were \(args)")
        // -u is a 5s no-op without -t; it must not be present.
        expect(!args.contains { $0.contains("u") }, "the dead -u flag must not be included")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("CaffeineStateTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
