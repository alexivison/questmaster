import Foundation
import QuestmasterCore

struct TrackerSessionShortcutsTests {
    static func run() {
        sessionIDAtPositionRespectsBounds()
        sessionIDAtPositionOnEmptyListReturnsNil()
        numbersByIDMatchesFlatOrderAndCapsAtNine()
        print("TrackerSessionShortcutsTests: all tests passed")
    }

    private static func sessionIDAtPositionRespectsBounds() {
        let sessions = makeSessions(count: 3)

        expect(TrackerSessionShortcuts.sessionID(atPosition: 1, in: sessions) == "s1", "position 1 should map to first session")
        expect(TrackerSessionShortcuts.sessionID(atPosition: 3, in: sessions) == "s3", "position 3 should map to third session")
        expect(TrackerSessionShortcuts.sessionID(atPosition: 4, in: sessions) == nil, "position beyond row count should be nil")
        expect(TrackerSessionShortcuts.sessionID(atPosition: 0, in: sessions) == nil, "position 0 should be nil")
    }

    private static func sessionIDAtPositionOnEmptyListReturnsNil() {
        expect(TrackerSessionShortcuts.sessionID(atPosition: 1, in: []) == nil, "empty session list should never resolve a position")
    }

    private static func numbersByIDMatchesFlatOrderAndCapsAtNine() {
        let sessions = makeSessions(count: 12)
        let numbers = TrackerSessionShortcuts.numbersByID(sessions)

        expect(numbers.count == 9, "numbering should cap at nine sessions, got \(numbers.count)")
        for position in 1...9 {
            expect(numbers["s\(position)"] == position, "session s\(position) should map to number \(position)")
        }
        expect(numbers["s10"] == nil, "tenth-and-later sessions should get no number")
    }

    private static func makeSessions(count: Int) -> [TrackerSession] {
        (1...count).map { index in
            TrackerSession(id: "s\(index)", title: "Session \(index)", repoName: "repo")
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("TrackerSessionShortcutsTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
