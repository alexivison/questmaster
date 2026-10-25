import Foundation
import QuestmasterCore

struct DaemonConnectionTests {
    static func run() {
        recordAndUpgradeNudge()
        handshakeValidation()
        waitingStatus()
        oldEnvelopeIsIncompatible()
        print("DaemonConnectionTests: all tests passed")
    }

    private static func record() throws -> DaemonRecord {
        try JSONDecoder().decode(DaemonRecord.self, from: Data("""
        {"running":true,"root":"/state","identity":"canonical","socket":"/state/daemon/canonical.sock","executable":"/bin/qm","shim_directory":"/state/daemon/bin/canonical","build":"old","generation":3,"accepting":true}
        """.utf8))
    }

    private static func handshake(_ root: String = "/state", _ identity: String = "canonical", _ version: Int = 2, _ accepting: Bool = true) throws -> DaemonHandshake {
        let value: [String: Any] = ["root": root, "identity": identity, "protocol_version": version, "accepting": accepting]
        return try JSONDecoder().decode(DaemonHandshake.self, from: JSONSerialization.data(withJSONObject: value))
    }

    private static func recordAndUpgradeNudge() {
        do {
            let value = try record()
            expect(value.socket == "/state/daemon/canonical.sock" && value.generation == 3, "daemon record should decode endpoint and generation")
            expect(value.shimDirectory == "/state/daemon/bin/canonical", "daemon record should supply the shim directory")
            expect(value.shouldCheckUpgrade(diskBuild: "new"), "different disk build should trigger a nudge")
            expect(!value.shouldCheckUpgrade(diskBuild: "old") && !value.shouldCheckUpgrade(diskBuild: nil), "matching or unreadable disk build should not nudge")
        } catch { fail("daemon record: \(error)") }
    }

    private static func handshakeValidation() {
        do {
            let value = try record()
            try handshake().validate(against: value)
            for hello in [try handshake("/other"), try handshake("/state", "other"), try handshake("/state", "canonical", 1), try handshake("/state", "canonical", 2, false)] {
                do {
                    try hello.validate(against: value)
                    fail("invalid handshake was accepted")
                } catch { /* Expected. */ }
            }
        } catch { fail("handshake validation: \(error)") }
    }

    private static func waitingStatus() {
        expect(DaemonWaitingStatus.message(after: 4.9) == "connecting to backend...", "early wait should show connection status")
        expect(DaemonWaitingStatus.message(after: 5) == "backend finishing a previous operation", "five-second wait should explain the handoff")
    }

    private static func oldEnvelopeIsIncompatible() {
        let line = Data("{\"protocol_version\":1,\"type\":\"event\",\"topic\":\"tracker\",\"data\":{\"sessions\":[]}}".utf8)
        do {
            _ = try ServeContract.update(fromLine: line)
            fail("old envelope was accepted")
        } catch let error as ServeClientError {
            expect(error.isProtocolVersionMismatch, "old envelope should enter incompatible state")
        } catch { fail("old envelope raised unexpected error: \(error)") }
    }

    private static func expect(_ condition: Bool, _ message: String) {
        if !condition { fail(message) }
    }

    private static func fail(_ message: String) {
        fputs("DaemonConnectionTests failed: \(message)\n", stderr)
        exit(1)
    }
}
