import Foundation
import QuestmasterCore

struct ServeConnectionDisplayTests {
    static func run() {
        processStatusesMapToConnectionState()
        runtimeStatusesMapToConnectionStateWithoutLeakingText()
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
            ServeConnectionStatus.state(forProcessStatus: "app-launched serve did not become ready: /tmp/serve.sock") == .error,
            "process not-ready status should map to error"
        )
        expect(
            ServeConnectionStatus.state(forProcessStatus: "app-launched serve exited before socket was ready: 1") == .error,
            "process exited-before-ready status should map to error"
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

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("ServeConnectionDisplayTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
