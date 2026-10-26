import Foundation

/// Where the dock's two panels sit in its column. Version Control is a fixed 300 tall on top, the bottom panel takes the
/// rest, 20 under it; a panel alone fills the column. Offsets run down from the column's top edge.
public struct DockColumnLayout: Equatable {
    /// The Version Control panel's height when the bottom panel shows too: 300, as its design draws it.
    public static let versionControlHeight = 300.0
    /// Between the two panels: the shell gap (`Space.section`).
    public static let panelGap = 20.0

    public struct Slot: Equatable {
        public let offset: Double
        public let height: Double

        public init(offset: Double, height: Double) {
            self.offset = offset
            self.height = height
        }
    }

    public let top: Slot?
    public let bottom: Slot?

    public static func make(height: Double, panels: DockPanels) -> DockColumnLayout {
        switch (panels.top, panels.bottom) {
        case (false, false):
            return DockColumnLayout(top: nil, bottom: nil)
        case (true, false):
            return DockColumnLayout(top: Slot(offset: 0, height: height), bottom: nil)
        case (false, true):
            return DockColumnLayout(top: nil, bottom: Slot(offset: 0, height: height))
        case (true, true):
            let topHeight = min(versionControlHeight, max(0, height - panelGap))
            let bottomOffset = topHeight + panelGap
            return DockColumnLayout(
                top: Slot(offset: 0, height: topHeight),
                bottom: Slot(offset: bottomOffset, height: max(0, height - bottomOffset))
            )
        }
    }
}
