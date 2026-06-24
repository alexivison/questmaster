import Foundation
import QuestmasterCore

struct ServeConnectionDisplayTests {
    static func run() {
        processStatusesMapToConnectionState()
        runtimeStatusesMapToConnectionStateWithoutLeakingText()
        protocolMismatchLatchIsSticky()
        serveRespawnPolicyBoundsRetriesAndResetsAfterReady()
        print("ServeConnectionDisplayTests: all tests passed")
    }

    private static func processStatusesMapToConnectionState() {
        expect(
            ServeConnectionStatus.state(forProcessStatus: "app-launched serve starting: /bin/qm /tmp/serve.sock") == .starting,
            "process starting status should map to starting"
        )
        expect(
            ServeConnectionStatus.state(forProcessStatus: "app-launched serve ready: /tmp/serve.sock") == .ready,
            "process ready status should map to ready"
        )
        expect(
            ServeConnectionStatus.state(forProcessStatus: "serve launch failed: permission denied") == .error,
            "process failure status should map to error"
        )
        expect(
            ServeConnectionStatus.state(forProcessStatus: "app-launched serve did not become ready: /tmp/serve.sock") == .starting,
            "process not-ready status should keep the retrying UI in starting state"
        )
        expect(
            ServeConnectionStatus.state(forProcessStatus: "app-launched serve exited before socket was ready: 1") == .error,
            "process exited-before-ready status should map to error"
        )
        expect(
            ServeConnectionStatus.state(forProcessStatus: "app-launched serve stopped after restart limit") == .error,
            "restart exhaustion should map to error"
        )
    }

    private static func runtimeStatusesMapToConnectionStateWithoutLeakingText() {
        expect(
            ServeConnectionStatus.state(forRuntimeStatus: "serve socket connected: /tmp/serve.sock") == .ready,
            "runtime connected status should map to ready"
        )
        expect(
            ServeConnectionStatus.state(forRuntimeStatus: "serve not connected - retrying: connection refused") == .starting,
            "runtime reconnect status should map to starting"
        )
        expect(
            ServeConnectionStatus.state(forRuntimeStatus: "serve decode failed: protocol mismatch") == .error,
            "runtime decode failure should map to error"
        )

        expect(
            ServeConnectionStatus.state(forRuntimeStatus: "directory suggestion failed") == nil,
            "unrelated directory status should not map to serve connection state"
        )
    }

    private static func protocolMismatchLatchIsSticky() {
        var latch = ServeProtocolMismatchLatch()
        let first = latch.record(
            ServeClientError.protocolError("serve protocol incompatible: expected protocol_version 1, got 2")
        )
        let second = latch.record(
            ServeClientError.protocolError("serve protocol incompatible: expected protocol_version 1, got 3")
        )

        expect(latch.isLatched, "protocol mismatch should latch")
        expect(first == "serve protocol incompatible: expected protocol_version 1, got 2", "first mismatch message not returned")
        expect(second == first, "latched mismatch should keep the first incompatible state")
        expect(
            latch.record(ServeClientError.protocolError("temporary decode error")) == nil,
            "non-version protocol errors should not latch"
        )
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
            fputs("ServeConnectionDisplayTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
