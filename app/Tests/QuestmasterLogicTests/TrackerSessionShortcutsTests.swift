import Foundation
import QuestmasterCore

struct TrackerSessionShortcutsTests {
    static func run() {
        sessionIDAtPositionRespectsBounds()
        sessionIDAtPositionOnEmptyListReturnsNil()
        numbersByIDMatchesFlatOrderAndCapsAtNine()
        selectableSessionsHidesCollapsedWorkers()
        sessionIDAtPositionMatchesNumbersByIDWhenCollapsed()
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

    // Group C regression: a worker hidden by its master's collapse toggle must be excluded
    // from both the badge numbering (SwiftUI tracker) and the Cmd+1..9 lookup (AppDelegate),
    // or the two drift out of sync.
    private static func selectableSessionsHidesCollapsedWorkers() {
        let sessions = makeMasterWithWorkers()
        let selectable = TrackerSessionShortcuts.selectableSessions(sessions, collapsedMasterIDs: ["master-1"])

        expect(selectable.map(\.id) == ["master-1", "root-2"], "collapsed worker rows should be excluded: got \(selectable.map(\.id))")
    }

    private static func sessionIDAtPositionMatchesNumbersByIDWhenCollapsed() {
        let sessions = makeMasterWithWorkers()
        let selectable = TrackerSessionShortcuts.selectableSessions(sessions, collapsedMasterIDs: ["master-1"])
        let numbers = TrackerSessionShortcuts.numbersByID(selectable)

        for (id, position) in numbers {
            expect(
                TrackerSessionShortcuts.sessionID(atPosition: position, in: selectable) == id,
                "position \(position) should resolve back to \(id) once workers are collapsed"
            )
        }
        expect(TrackerSessionShortcuts.sessionID(atPosition: 2, in: selectable) == "root-2", "position 2 should skip the collapsed worker and land on root-2")
    }

    private static func makeMasterWithWorkers() -> [TrackerSession] {
        [
            TrackerSession(id: "master-1", title: "Master", repoName: "repo", role: "master"),
            TrackerSession(id: "worker-1", title: "Worker", repoName: "repo", role: "worker", parentID: "master-1"),
            TrackerSession(id: "root-2", title: "Standalone", repoName: "repo"),
        ]
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
