import Foundation
import QuestmasterCore

struct TrackerHeaderAlignmentTests {
    static func run() {
        firstRowCenterIsGapPlusHalfACell()
        headerTopOffsetCentersTheRowOnTheFirstRow()
        tallerHeaderRowNeedsLessTopOffset()
        print("TrackerHeaderAlignmentTests: all tests passed")
    }

    private static func firstRowCenterIsGapPlusHalfACell() {
        let center = TrackerHeaderAlignment.terminalFirstRowCenter(gap: 20, cellHeight: 18)
        expect(center == 29, "gap(20) + cellHeight(18)/2 should be 29, got \(center)")
    }

    private static func headerTopOffsetCentersTheRowOnTheFirstRow() {
        // First-row centre at 29 (above); a 14pt header row needs its top 7pt above that centre.
        let offset = TrackerHeaderAlignment.headerTopOffset(gap: 20, cellHeight: 18, headerRowHeight: 14)
        expect(offset == 22, "29 - 14/2 should be 22, got \(offset)")
    }

    private static func tallerHeaderRowNeedsLessTopOffset() {
        let shortRow = TrackerHeaderAlignment.headerTopOffset(gap: 20, cellHeight: 18, headerRowHeight: 14)
        let tallRow = TrackerHeaderAlignment.headerTopOffset(gap: 20, cellHeight: 18, headerRowHeight: 20)
        expect(tallRow < shortRow, "a taller header row should need a smaller top offset to keep the same centre, got \(tallRow) vs \(shortRow)")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("TrackerHeaderAlignmentTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
