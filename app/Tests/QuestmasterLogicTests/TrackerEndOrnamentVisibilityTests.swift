import Foundation
import QuestmasterCore

struct TrackerEndOrnamentVisibilityTests {
    static func run() {
        showsWhenContentAndOrnamentFit()
        showsAtTheExactFitBoundary()
        hidesWhenTheOrnamentWouldOverflow()
        print("TrackerEndOrnamentVisibilityTests: all tests passed")
    }

    private static func showsWhenContentAndOrnamentFit() {
        expect(
            TrackerEndOrnamentVisibility.shows(contentHeight: 120, viewportHeight: 200, ornamentHeight: 44),
            "footer should show when content and ornament fit"
        )
    }

    private static func showsAtTheExactFitBoundary() {
        expect(
            TrackerEndOrnamentVisibility.shows(contentHeight: 156, viewportHeight: 200, ornamentHeight: 44),
            "footer should show at the exact fit boundary"
        )
    }

    private static func hidesWhenTheOrnamentWouldOverflow() {
        expect(
            !TrackerEndOrnamentVisibility.shows(contentHeight: 157, viewportHeight: 200, ornamentHeight: 44),
            "footer should hide when it would overflow"
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("TrackerEndOrnamentVisibilityTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
