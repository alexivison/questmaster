import Foundation
import QuestmasterCore

struct StartupTerminalSwitchGuardTests {
    static func run() {
        suppressesNonUserSwitchAwayFromStartupSession()
        allowsUserInitiatedSwitches()
        allowsSwitchesAfterUserSwitchOccurred()
        allowsSwitchesWhenTerminalAlreadyMovedFromStartupSession()
        print("StartupTerminalSwitchGuardTests: all tests passed")
    }

    private static func suppressesNonUserSwitchAwayFromStartupSession() {
        expect(
            StartupTerminalSwitchGuard.shouldSuppress(
                startupSessionID: "qm-restored",
                currentTerminalSessionID: " qm-restored ",
                targetSessionID: "qm-master",
                userInitiated: false,
                userSwitchHasOccurred: false
            ),
            "non-user startup switch away from restored terminal should be suppressed"
        )
    }

    private static func allowsUserInitiatedSwitches() {
        expect(
            !StartupTerminalSwitchGuard.shouldSuppress(
                startupSessionID: "qm-restored",
                currentTerminalSessionID: "qm-restored",
                targetSessionID: "qm-worker",
                userInitiated: true,
                userSwitchHasOccurred: false
            ),
            "user-initiated switch should not be suppressed"
        )
    }

    private static func allowsSwitchesAfterUserSwitchOccurred() {
        expect(
            !StartupTerminalSwitchGuard.shouldSuppress(
                startupSessionID: "qm-restored",
                currentTerminalSessionID: "qm-restored",
                targetSessionID: "qm-master",
                userInitiated: false,
                userSwitchHasOccurred: true
            ),
            "non-user switches after a user switch should not be suppressed"
        )
    }

    private static func allowsSwitchesWhenTerminalAlreadyMovedFromStartupSession() {
        expect(
            !StartupTerminalSwitchGuard.shouldSuppress(
                startupSessionID: "qm-restored",
                currentTerminalSessionID: "qm-worker",
                targetSessionID: "qm-master",
                userInitiated: false,
                userSwitchHasOccurred: false
            ),
            "guard should only protect while terminal is still on startup session"
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("StartupTerminalSwitchGuardTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
