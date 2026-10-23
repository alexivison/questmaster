import Foundation
import QuestmasterCore

struct ServeRecoveryPolicyTests {
    static func run() {
        serveRespawnPolicyBoundsRetriesAndResetsAfterReady()
        print("ServeRecoveryPolicyTests: all tests passed")
    }

    private static func serveRespawnPolicyBoundsRetriesAndResetsAfterReady() {
        var policy = ServeRespawnPolicy(maxRestarts: 2, delays: [0.1, 0.2])

        expect(policy.nextDelay() == 0.1, "first respawn delay mismatch")
        expect(policy.nextDelay() == 0.2, "second respawn delay mismatch")
        expect(policy.nextDelay() == nil, "respawn policy should stop after max restarts")

        policy.reset()
        expect(policy.nextDelay() == 0.1, "respawn policy should reset after serve is ready")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("ServeRecoveryPolicyTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
