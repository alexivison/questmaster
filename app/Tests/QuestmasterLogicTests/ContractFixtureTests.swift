import Foundation
import QuestmasterCore

struct ContractFixtureTests {
    static func run() {
        do {
            try payloadFixturesDecode()
            try envelopeFixturesDecode()
            print("ContractFixtureTests: all tests passed")
        } catch {
            fail("contract fixtures threw \(error)")
        }
    }

    private static func payloadFixturesDecode() throws {
        let tracker = try decodeFixture(TrackerSnapshot.self, "tracker_payload.json")
        guard let session = tracker.repos.first?.sessions.first else {
            fail("tracker session missing")
        }
        expect(session.id == "qm-demo", "tracker session id did not decode")
        expect(session.repoIdentity == "/tmp/questmaster/.git", "tracker repo identity did not decode")
        expect(session.repoColor == "green", "tracker repo color did not decode")
        expect(session.displayColor == "violet", "tracker display color did not decode")
        expect(session.workerCount == 1, "tracker worker count did not decode")
        expect(session.duration == "2m0s", "tracker elapsed_ms did not decode")
        expect(session.artifacts.first?.label == "Plan", "tracker artifact did not decode")
        expect(Set(session.artifacts.map(\.kind)) == Set(["html", "markdown", "image"]), "tracker artifact kinds did not decode")

        let suggestions = try decodeFixture(DirSuggestFixture.self, "dir_suggest_payload.json")
        expect(suggestions.suggestions == ["/tmp/project-app", "/tmp/project-log"], "dir_suggest suggestions did not decode")
        expect(suggestions.recents == ["/tmp/project-app"], "dir_suggest recents did not decode")
    }

    private static func envelopeFixturesDecode() throws {
        let tracker = try requireUpdate("tracker_event_envelope.json")
        expect(tracker.tracker?.repos.first?.sessions.first?.lastKind == "PreToolUse", "tracker event did not decode")
        expect(tracker.tracker?.repos.first?.sessions.first?.isCurrent == true, "tracker event is_current did not decode")

        let trackerResponse = try requireUpdate("tracker_response_envelope.json")
        expect(trackerResponse.tracker?.repos.first?.sessions.first?.id == "qm-demo", "tracker response did not decode")
    }

    private static func decodeFixture<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONDecoder().decode(T.self, from: fixtureData(name))
    }

    private static func requireUpdate(_ name: String) throws -> RuntimeUpdate {
        guard let update = try ServeContract.update(fromLine: fixtureData(name)) else {
            throw ContractFixtureError("fixture \(name) produced no update")
        }
        return update
    }

    private static func fixtureData(_ name: String) throws -> Data {
        try Data(contentsOf: contractTestdataDir().appendingPathComponent(name))
    }

    private static func contractTestdataDir() throws -> URL {
        var url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        for _ in 0..<8 {
            let candidate = url.appendingPathComponent("internal/serve/testdata", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            url.deleteLastPathComponent()
        }

        url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()
        for _ in 0..<8 {
            let candidate = url.appendingPathComponent("internal/serve/testdata", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            url.deleteLastPathComponent()
        }

        throw ContractFixtureError("could not find internal/serve/testdata")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fail(message)
        }
    }

    private static func fail(_ message: String) -> Never {
        fputs("ContractFixtureTests failed: \(message)\n", stderr)
        Foundation.exit(1)
    }
}

private struct DirSuggestFixture: Decodable {
    var suggestions: [String]
    var recents: [String]
}

private struct ContractFixtureError: Error, CustomStringConvertible {
    var description: String

    init(_ description: String) {
        self.description = description
    }
}
