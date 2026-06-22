import Foundation
import QuestmasterCore

struct ServeConnectionDisplayTests {
    static func run() {
        displayUsesShortStableLabels()
        processStatusesMapToConnectionState()
        runtimeStatusesMapToConnectionStateWithoutLeakingText()
        print("ServeConnectionDisplayTests: all tests passed")
    }

    private static func displayUsesShortStableLabels() {
        expect(
            ServePillDisplay.display(for: .ready) == ServePillDisplay(label: "serve", indicator: .dot, tone: .ready),
            "ready display should be the clean serve label"
        )
        expect(
            ServePillDisplay.display(for: .starting) == ServePillDisplay(label: "starting serve…", indicator: .spinner, tone: .starting),
            "starting display should use the stable starting label"
        )
        expect(
            ServePillDisplay.display(for: .error) == ServePillDisplay(label: "serve error", indicator: .dot, tone: .error),
            "error display should not leak raw status"
        )
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

        let errorDisplay = ServePillDisplay.display(for: .error)
        expect(!errorDisplay.label.contains("decode"), "error label leaked raw decode text")
        expect(!errorDisplay.label.contains("directory"), "error label leaked unrelated directory text")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("ServeConnectionDisplayTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
