import Foundation
import QuestmasterCore

struct DaemonConnectionTests {
    static func run() {
        recordAndUpgradeNudge()
        handshakeValidation()
        oldEnvelopeIsIncompatible()
        binaryHashIsReusedUntilTheFileChanges()
        anUnreadableBinaryHasNoHashAndKeepsNothing()
        print("DaemonConnectionTests: all tests passed")
    }

    private static func record() throws -> DaemonRecord {
        try JSONDecoder().decode(DaemonRecord.self, from: Data("""
        {"running":true,"root":"/state","identity":"canonical","socket":"/state/daemon/canonical.sock","executable":"/bin/qm","shim_directory":"/state/daemon/bin/canonical","build":"old","generation":3,"accepting":true}
        """.utf8))
    }

    private static func handshake(_ root: String = "/state", _ identity: String = "canonical", _ version: Int = 3, _ accepting: Bool = true) throws -> DaemonHandshake {
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
            for hello in [try handshake("/other"), try handshake("/state", "other"), try handshake("/state", "canonical", 3, false)] {
                do {
                    try hello.validate(against: value)
                    fail("invalid handshake was accepted")
                } catch ServeClientError.protocolMismatch {
                    fail("a handshake with the right version should not read as a mismatch")
                } catch { /* Expected. */ }
            }
            do {
                try handshake("/state", "canonical", 1).validate(against: value)
                fail("an old handshake was accepted")
            } catch ServeClientError.protocolMismatch {
                // Expected: the app reads the backend as incompatible.
            }
        } catch { fail("handshake validation: \(error)") }
    }

    private static func oldEnvelopeIsIncompatible() {
        let line = Data("{\"protocol_version\":1,\"type\":\"event\",\"topic\":\"tracker\",\"data\":{\"sessions\":[]}}".utf8)
        do {
            _ = try ServeContract.update(fromLine: line)
            fail("old envelope was accepted")
        } catch ServeClientError.protocolMismatch {
            // Expected: the old envelope enters the incompatible state.
        } catch { fail("old envelope raised unexpected error: \(error)") }
    }

    private static func binaryHashIsReusedUntilTheFileChanges() {
        var cache = BinaryHashCache()
        var computed = 0
        func hash(_ fingerprint: BinaryHashCache.Fingerprint) -> String? {
            cache.hash(of: fingerprint) {
                computed += 1
                return "hash-\(computed)"
            }
        }
        let built = Date(timeIntervalSince1970: 1_000)
        let binary = BinaryHashCache.Fingerprint(path: "/state/bin/qm", size: 100, modified: built)

        expect(hash(binary) == "hash-1" && hash(binary) == "hash-1", "an unchanged binary should reuse its hash")
        expect(computed == 1, "an unchanged binary should be hashed once, got \(computed)")
        let changes = [
            BinaryHashCache.Fingerprint(path: "/state/bin/qm", size: 101, modified: built),
            BinaryHashCache.Fingerprint(path: "/state/bin/qm", size: 101, modified: built.addingTimeInterval(0.001)),
            BinaryHashCache.Fingerprint(path: "/state/bin/other-qm", size: 101, modified: built.addingTimeInterval(0.001)),
        ]
        for (index, changed) in changes.enumerated() {
            expect(hash(changed) == "hash-\(index + 2)", "a new size, modification time or path should hash again")
        }
        expect(computed == 4, "each change should hash once, got \(computed)")
    }

    private static func anUnreadableBinaryHasNoHashAndKeepsNothing() {
        var cache = BinaryHashCache()
        var computed = 0
        let binary = BinaryHashCache.Fingerprint(path: "/state/bin/qm", size: 100, modified: Date(timeIntervalSince1970: 1_000))
        expect(cache.hash(of: nil) { computed += 1; return "unused" } == nil && computed == 0, "a missing file should have no hash and not be read")
        expect(cache.hash(of: binary) { computed += 1; return nil } == nil, "an unreadable file should have no hash")
        expect(cache.hash(of: binary) { computed += 1; return "hash" } == "hash" && computed == 2, "a failed hash should not be kept")
    }

    private static func expect(_ condition: Bool, _ message: String) {
        if !condition { fail(message) }
    }

    private static func fail(_ message: String) {
        fputs("DaemonConnectionTests failed: \(message)\n", stderr)
        exit(1)
    }
}
