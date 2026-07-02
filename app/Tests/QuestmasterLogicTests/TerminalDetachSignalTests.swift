import Foundation
import QuestmasterCore

struct TerminalDetachSignalTests {
    static func run() {
        markerMatchesExactly()
        nonMarkersDoNotMatch()
        print("TerminalDetachSignalTests: all tests passed")
    }

    private static func markerMatchesExactly() {
        expect(TerminalDetachSignal.isDetachMarker(TerminalDetachSignal.markerTitle), "marker title should match")
    }

    private static func nonMarkersDoNotMatch() {
        for title in ["", "questmaster", "prefix-\(TerminalDetachSignal.markerTitle)", "\(TerminalDetachSignal.markerTitle)-suffix"] {
            expect(!TerminalDetachSignal.isDetachMarker(title), "\(title) should not match")
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("TerminalDetachSignalTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
