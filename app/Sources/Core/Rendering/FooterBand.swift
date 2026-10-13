import Foundation

/// The band the shell reserves at the window's bottom for the footer. The footer's plate sets the height
/// it occupies. The shell gap sits below the plate, and a flush gap sits above it (Ghostty's own padding
/// supplies the rest of the gap above the terminal). Ornaments that overflow the plate draw over the gap
/// and reserve nothing, so they never appear here.
public struct FooterBand: Equatable {
    public let plateHeight: Double
    public let bottomGap: Double
    public let topGap: Double

    public init(plateHeight: Double, bottomGap: Double, topGap: Double) {
        self.plateHeight = plateHeight
        self.bottomGap = bottomGap
        self.topGap = topGap
    }

    /// Where the terminal's bottom edge stops, measured up from the window's bottom edge.
    public var reservedHeight: Double {
        plateHeight + bottomGap + topGap
    }

    /// Where the plate's bottom edge sits above the window's bottom edge: the shell gap, plus the
    /// terminal row-snap leftover that lands below the footer.
    public func plateBottomInset(snapLeftover: Double) -> Double {
        bottomGap + snapLeftover
    }
}
