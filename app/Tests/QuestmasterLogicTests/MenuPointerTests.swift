import Foundation
import QuestmasterCore

/// The keyboard cursor's menu pointer: the 6 by 7 arrow, its ink, its frame at a pixel size, and where it sits beside a card.
struct MenuPointerTests {
    static func run() {
        theArrowIsSixBySevenWithItsInkInFourColumns()
        theFrameIsWholePointsPerPixel()
        theArrowSitsOutsideTheCardAndCentred()
        print("MenuPointerTests: all tests passed")
    }

    private static func theArrowIsSixBySevenWithItsInkInFourColumns() {
        expect(MenuPointer.columns == 6 && MenuPointer.rows == 7, "the arrow should be 6 by 7 pixels")
        let drawn = (0..<MenuPointer.rows).map { row in
            (0..<MenuPointer.columns).map { MenuPointer.isOn(column: $0, row: row) ? "#" : "." }.joined()
        }
        expect(drawn == ["#.....", "##....", "###...", "####..", "###...", "##....", "#....."], "the arrow's pixels should be the menu pointer, got \(drawn)")
        expect(MenuPointer.inkColumns == 4, "the arrow's ink should be 4 columns wide, the rest blank")
        expect(!MenuPointer.isOn(column: 6, row: 0) && !MenuPointer.isOn(column: 0, row: 7) && !MenuPointer.isOn(column: -1, row: 0), "pixels off the arrow should be off")
    }

    private static func theFrameIsWholePointsPerPixel() {
        expect(MenuPointer.size(pixel: 1) == CGSize(width: 6, height: 7), "a 1pt pixel should frame the arrow at 6 by 7")
        expect(MenuPointer.size(pixel: 2) == CGSize(width: 12, height: 14), "a 2pt pixel should frame the arrow at 12 by 14")
    }

    private static func theArrowSitsOutsideTheCardAndCentred() {
        expect(MenuPointer.leadingOffset(gap: 5, pixel: 2) == -17, "a 2pt arrow's frame should end 5 outside the card: -17 from its leading edge")
        expect(MenuPointer.leadingOffset(gap: 5, pixel: 1) == -11, "a 1pt arrow's frame should end 5 outside the card")
        expect(MenuPointer.topOffset(rowHeight: 50, pixel: 2) == 18, "a 2pt arrow should centre on a 50pt row")
        expect(MenuPointer.topOffset(rowHeight: 50, pixel: 1) == 21, "a 1pt arrow's centring should stay on whole points (21.5 rounds down)")
        expect(MenuPointer.topOffset(rowHeight: 30, pixel: 2) == 8, "a 2pt arrow should centre on a 30pt row")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fatalError(message)
        }
    }
}
