import Foundation
import QuestmasterCore

struct NewTerminalLogicTests {
    static func run() {
        planPrefersSelectedWorktree()
        planFallsBackToConfigThenHome()
        planIgnoresWhitespaceCandidates()
        print("NewTerminalLogicTests: all tests passed")
    }

    private static func planPrefersSelectedWorktree() {
        let plan = NewTerminalLogic.plan(
            selectedWorktreePath: " /repos/app ",
            configWorkingDirectory: "/config",
            homeDirectory: "/Users/aleksi"
        )

        expect(plan.cwd == "/repos/app", "selected worktree should win")
        expect(plan.title == "Shell", "title should be static")
    }

    private static func planFallsBackToConfigThenHome() {
        let configPlan = NewTerminalLogic.plan(
            selectedWorktreePath: nil,
            configWorkingDirectory: "/config/work",
            homeDirectory: "/Users/aleksi"
        )
        expect(configPlan.cwd == "/config/work", "config directory should be first fallback")
        expect(configPlan.title == "Shell", "config title should be static")

        let homePlan = NewTerminalLogic.plan(
            selectedWorktreePath: nil,
            configWorkingDirectory: nil,
            homeDirectory: "/Users/aleksi"
        )
        expect(homePlan.cwd == "/Users/aleksi", "home should be final fallback")
        expect(homePlan.title == "Shell", "home title should be static")
    }

    private static func planIgnoresWhitespaceCandidates() {
        let plan = NewTerminalLogic.plan(
            selectedWorktreePath: " ",
            configWorkingDirectory: "\n/tmp/fallback\t",
            homeDirectory: "/Users/aleksi"
        )

        expect(plan.cwd == "/tmp/fallback", "blank selected path should be ignored")
        expect(plan.title == "Shell", "fallback title should be static")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("NewTerminalLogicTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
