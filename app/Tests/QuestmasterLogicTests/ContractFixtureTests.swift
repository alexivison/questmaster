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
        let board = try decodeFixture(BoardSnapshot.self, "board_payload.json")
        expect(board.repos.first?.id == "questmaster", "board repo did not decode")
        expect(board.repos.first?.quests.first?.id == "DEMO-1", "board quest did not decode")
        expect(board.repos.first?.quests.first?.runtime.loop?.lastVerdict == "fail", "board runtime loop did not decode")

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
        expect(session.questID == "DEMO-1", "tracker quest_id did not decode")
        expect(session.questTitle == "Serve runtime JSON", "tracker quest_title did not decode")

        let quest = try decodeFixture(QuestPayload.self, "quest_payload.json")
        expect(quest.observedLabel == "2026-06-19T04:20:00Z", "quest observed_at did not decode")
        expect(quest.quest.id == "DEMO-1", "quest id did not decode")
        expect(quest.quest.runtime.sessionDetails.first?.id == "qm-demo", "quest session_details did not decode")
        expect(quest.quest.runtime.gatesAt["tests"] == "2026-06-19T04:19:30Z", "quest gates_at did not decode")

        let items = try decodeFixture(ItemsPayload.self, "items_payload.json")
        let item = try require(items.items.first, "items payload missing workspace item")
        expect(item.id == "item-plan", "workspace item id did not decode")
        expect(item.artifact.inline == "<h1>Plan</h1>", "workspace artifact inline did not decode")
        expect(item.attachmentCount == 1, "workspace attachment_count did not decode")
        expect(item.questIDs == ["DEMO-1"], "workspace quest_ids did not decode")

        let activeItem = try decodeFixture(RuntimeViewerItem.self, "active_item_payload.json")
        expect(activeItem.questID == "DEMO-1", "active item quest_id did not decode")
        expect(activeItem.path == "/tmp/plan.html", "active item path did not decode")
        expect(activeItem.normalizedType == "html", "active item type did not normalize")

        let suggestions = try decodeFixture(DirSuggestFixture.self, "dir_suggest_payload.json")
        expect(suggestions.suggestions == ["/tmp/questmaster-app", "/tmp/quest-log"], "dir_suggest suggestions did not decode")
        expect(suggestions.recents == ["/tmp/questmaster-app"], "dir_suggest recents did not decode")
    }

    private static func envelopeFixturesDecode() throws {
        let board = try requireUpdate("board_response_envelope.json")
        expect(board.observedLabel == "2026-06-19T04:20:00Z", "board envelope observed_at did not decode")
        expect(board.board?.repos.first?.quests.first?.title == "Serve runtime JSON", "board envelope did not decode")

        let tracker = try requireUpdate("tracker_event_envelope.json")
        expect(tracker.tracker?.repos.first?.sessions.first?.lastKind == "PreToolUse", "tracker event did not decode")
        expect(tracker.tracker?.repos.first?.sessions.first?.isCurrent == true, "tracker event is_current did not decode")

        let activeItem = try requireUpdate("active_item_event_envelope.json")
        expect(activeItem.viewerItem?.html == "<h1>Plan</h1>", "active item event html did not decode")
        expect(activeItem.viewerItem?.questID == "DEMO-1", "active item event quest_id did not decode")
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
            let candidate = url.appendingPathComponent("contract/testdata", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            url.deleteLastPathComponent()
        }

        url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()
        for _ in 0..<8 {
            let candidate = url.appendingPathComponent("contract/testdata", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            url.deleteLastPathComponent()
        }

        throw ContractFixtureError("could not find contract/testdata")
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else {
            throw ContractFixtureError(message)
        }
        return value
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
