import Foundation
import QuestmasterCore

struct FooterBandTests {
    static func run() {
        reservedHeightIsThePlateWithBothGaps()
        gapsMeasureFromThePlateEdges()
        zeroGapsReserveOnlyThePlate()
        print("FooterBandTests: all tests passed")
    }

    private static func reservedHeightIsThePlateWithBothGaps() {
        let band = FooterBand(plateHeight: 53, bottomGap: 20, topGap: 4)
        expect(band.reservedHeight == 77, "reserved height should be plate + bottom gap + top gap, got \(band.reservedHeight)")
    }

    private static func gapsMeasureFromThePlateEdges() {
        let band = FooterBand(plateHeight: 53, bottomGap: 20, topGap: 4)
        expect(band.plateBottomInset(snapLeftover: 0) == 20, "plate bottom should sit one shell gap above the window bottom")
        expect(band.plateBottomInset(snapLeftover: 6) == 26, "row-snap leftover should add to the bottom gap, got \(band.plateBottomInset(snapLeftover: 6))")
    }

    private static func zeroGapsReserveOnlyThePlate() {
        let band = FooterBand(plateHeight: 53, bottomGap: 0, topGap: 0)
        expect(band.reservedHeight == 53, "with no gaps the band should be the plate alone")
        expect(band.plateBottomInset(snapLeftover: 0) == 0, "with no gaps the plate should sit on the window bottom")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fatalError(message)
        }
    }
}
