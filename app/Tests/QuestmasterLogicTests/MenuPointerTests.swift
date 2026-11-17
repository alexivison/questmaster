import Foundation
import QuestmasterCore

/// The keyboard cursor's menu pointer: its frame, its three outlines and where it sits beside a row.
struct MenuPointerTests {
    static func run() {
        theFrameIsTwelveByFourteenPoints()
        everyOutlineStaysInsideTheFrame()
        onlyTheChevronIsOpen()
        theNotchCutsTheBackEdge()
        theArrowSitsOutsideTheRowAndCentred()
        print("MenuPointerTests: all tests passed")
    }

    private static func theFrameIsTwelveByFourteenPoints() {
        expect(MenuPointer.width == 12 && MenuPointer.height == 14, "the pointer's frame should be 12 by 14 points, the old arrow's footprint")
    }

    /// The stroke is 1.5pt, so an outline point sits at least 0.75pt inside the frame on every side.
    private static func everyOutlineStaysInsideTheFrame() {
        let inset = 0.75
        for shape in MenuPointer.Shape.allCases {
            for point in MenuPointer.outline(shape) {
                expect(point.x >= inset && point.x <= Double(MenuPointer.width) - inset, "\(shape) should keep x inside the frame, got \(point.x)")
                expect(point.y >= inset && point.y <= Double(MenuPointer.height) - inset, "\(shape) should keep y inside the frame, got \(point.y)")
            }
        }
    }

    private static func onlyTheChevronIsOpen() {
        expect(MenuPointer.isFilled(.arrowhead), "the arrowhead should be a filled outline")
        expect(MenuPointer.isFilled(.notched), "the notched arrowhead should be a filled outline")
        expect(!MenuPointer.isFilled(.chevron), "the chevron should be an open line, stroked only")
    }

    /// The notch is a point inside the back edge, which sits at the outline's leftmost x.
    private static func theNotchCutsTheBackEdge() {
        let notched = MenuPointer.outline(.notched)
        let back = notched[0].x
        let notch = notched[3]
        expect(notched.count == 4, "the notched arrowhead should have four points, got \(notched.count)")
        expect(notch.x > back && notch.x < notched[1].x, "the notch should sit between the back edge and the tip")
        expect(notch.y == notched[1].y, "the notch should sit on the centre line, level with the tip")
    }

    private static func theArrowSitsOutsideTheRowAndCentred() {
        expect(MenuPointer.leadingOffset(gap: 5) == -17, "the frame should end 5 outside the row: -17 from its leading edge")
        expect(MenuPointer.topOffset(rowHeight: 50) == 18, "the pointer should centre on a 50pt row")
        expect(MenuPointer.topOffset(rowHeight: 45) == 15, "the pointer should centre on a 45pt row")
        expect(MenuPointer.topOffset(rowHeight: 30) == 8, "the pointer should centre on a 30pt row")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fatalError(message)
        }
    }
}
