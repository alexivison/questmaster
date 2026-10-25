import Foundation
import QuestmasterCore

struct ServeRecoveryPolicyTests {
    static func run() {
        serveRespawnPolicyBoundsRetriesAndResetsAfterReady()
        exhaustedPolicyRetriesAfterCooldownOrUserAction()
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

    private static func exhaustedPolicyRetriesAfterCooldownOrUserAction() {
        var policy = ServeRespawnPolicy(maxRestarts: 1, delays: [0])
        let now = Date(timeIntervalSince1970: 1_000)
        expect(policy.nextDelay() == 0 && policy.nextDelay() == nil, "first start cycle should exhaust")
        policy.coolDown(after: now)
        expect(!policy.canAttempt(now: now.addingTimeInterval(29)), "background retry should wait for cooldown")
        expect(policy.canAttempt(now: now.addingTimeInterval(30)), "background retry should resume after cooldown")
        expect(policy.nextDelay() == 0 && policy.nextDelay() == nil, "new start cycle should have its full retry budget")
        policy.coolDown(after: now)
        expect(!policy.canAttempt(now: now.addingTimeInterval(59)), "repeated failures should back off")
        expect(policy.canAttempt(now: now, userInitiated: true), "user action should bypass cooldown")
        policy.reset()
        policy.coolDown(after: now)
        expect(policy.canAttempt(now: now.addingTimeInterval(30)), "successful start should reset cooldown")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("ServeRecoveryPolicyTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
