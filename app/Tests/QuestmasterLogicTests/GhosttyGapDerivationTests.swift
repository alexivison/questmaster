import Foundation
import QuestmasterCore

struct GhosttyGapDerivationTests {
    static func run() {
        gIsTenMatchesTenPaddingGivesZero()
        gIsTwentyMatchesTenPaddingGivesTheShortfall()
        paddingLargerThanGStillGivesZero()
        print("GhosttyGapDerivationTests: all tests passed")
    }

    private static func gIsTenMatchesTenPaddingGivesZero() {
        let gap = GhosttyGapDerivation.flushGap(g: 10, ghosttyPadding: 10)
        expect(gap == 0, "G=10 with 10pt Ghostty padding should need no extra gap, got \(gap)")
    }

    private static func gIsTwentyMatchesTenPaddingGivesTheShortfall() {
        let gap = GhosttyGapDerivation.flushGap(g: 20, ghosttyPadding: 10)
        expect(gap == 10, "G=20 with 10pt Ghostty padding should need a 10pt extra gap, got \(gap)")
    }

    private static func paddingLargerThanGStillGivesZero() {
        let gap = GhosttyGapDerivation.flushGap(g: 10, ghosttyPadding: 14)
        expect(gap == 0, "Ghostty padding already past G should need no extra gap, got \(gap)")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("GhosttyGapDerivationTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
