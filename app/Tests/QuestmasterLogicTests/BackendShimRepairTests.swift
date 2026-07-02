import Foundation
import QuestmasterCore

struct BackendShimRepairTests {
    static func run() {
        devShimGuardsGoRunBehindWorktreeCd()
        staleDevShimRewritesToDirectBundleShim()
        liveDevShimStaysUnchanged()
        directShimStaysUnchanged()
        print("BackendShimRepairTests: all tests passed")
    }

    private static func devShimGuardsGoRunBehindWorktreeCd() {
        let script = BackendShimRepair.devScript(
            go: "/usr/local/bin/go",
            repoRoot: "/tmp/quest master/worktree",
            fallbackExecutable: "/Applications/Questmaster.app/Contents/Resources/qm"
        )

        expect(script.contains("cd '/tmp/quest master/worktree' && exec '/usr/local/bin/go' run . \"$@\""), "dev shim should gate go run behind cd")
        expect(script.contains("exec '/Applications/Questmaster.app/Contents/Resources/qm' \"$@\""), "dev shim should include bundled fallback")
        expect(!script.contains("\nexec '/usr/local/bin/go' run . \"$@\""), "dev shim should not run go from caller cwd")
    }

    private static func staleDevShimRewritesToDirectBundleShim() {
        let content = "#!/bin/sh\ncd '/tmp/deleted' && exec '/usr/local/bin/go' run . \"$@\"\nexec '/old/qm' \"$@\"\n"
        let decision = BackendShimRepair.repairDecision(
            content: content,
            fallbackExecutable: "/bundle/qm",
            directoryExists: { _ in false }
        )

        expect(decision.needsRewrite, "stale dev shim should rewrite")
        expect(decision.staleTargetDirectory == "/tmp/deleted", "stale target mismatch")
        expect(decision.replacementContent == BackendShimRepair.directScript(executable: "/bundle/qm"), "replacement should exec bundled qm")
    }

    private static func liveDevShimStaysUnchanged() {
        let content = "#!/bin/sh\ncd '/tmp/live' && exec '/usr/local/bin/go' run . \"$@\"\nexec '/bundle/qm' \"$@\"\n"
        let decision = BackendShimRepair.repairDecision(
            content: content,
            fallbackExecutable: "/bundle/qm",
            directoryExists: { $0 == "/tmp/live" }
        )

        expect(!decision.needsRewrite, "live dev shim should not rewrite")
    }

    private static func directShimStaysUnchanged() {
        let content = BackendShimRepair.directScript(executable: "/bundle/qm")
        let decision = BackendShimRepair.repairDecision(
            content: content,
            fallbackExecutable: "/other/qm",
            directoryExists: { _ in false }
        )

        expect(!decision.needsRewrite, "direct shim should not rewrite")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("BackendShimRepairTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
